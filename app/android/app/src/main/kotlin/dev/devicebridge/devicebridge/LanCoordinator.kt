package dev.devicebridge.devicebridge

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File
import java.net.Inet4Address
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Foreground-only discovery/listener. Owns no system configuration or VPN. */
class LanCoordinator(private val context: Context, private val event: (Map<String, Any?>) -> Unit) {
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val prefs = context.getSharedPreferences("devicebridge-lan", Context.MODE_PRIVATE)
    private val lock = context.getSystemService(WifiManager::class.java).createMulticastLock("DeviceBridge visible discovery").apply { setReferenceCounted(false) }
    private var visible = false
    private var initialized = false
    private var watching = false
    private var signature = ""
    @Volatile private var generation = 0
    @Volatile private var child: Process? = null
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { main.post { refresh() } }
        override fun onLost(network: Network) { main.post { refresh() } }
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) { main.post { refresh() } }
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { main.post { refresh() } }
    }

    fun networks(): List<Map<String, Any?>> = cm.allNetworks.mapNotNull { network ->
        val caps = cm.getNetworkCapabilities(network) ?: return@mapNotNull null
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@mapNotNull null
        val link = cm.getLinkProperties(network) ?: return@mapNotNull null
        val address = link.linkAddresses.firstOrNull { it.address is Inet4Address && it.address.isSiteLocalAddress } ?: return@mapNotNull null
        mapOf("interface" to link.interfaceName, "cidr" to "${address.address.hostAddress}/${address.prefixLength}",
            "network_handle" to network.networkHandle.toString(), "unmetered" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
            "metered" to if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) "Unmetered Wi-Fi" else "Metered Wi-Fi: explicit approval required")
    }

    fun activate(saved: Map<String, Any?>?) {
        initialized = true
        // Migrate a previously approved exact address without approving another network.
        if (prefs.getString("policy", null) == null && saved != null) {
            val current = networks().firstOrNull { it["cidr"] == saved["cidr"] && it["interface"] == saved["interface"] }
            if (current != null) approve(current + ("allow_wifi_roaming" to false))
        }
        refresh()
    }

    fun approve(selected: Map<String, Any?>) {
        val actual = networks().firstOrNull { it["network_handle"] == selected["network_handle"] && it["cidr"] == selected["cidr"] }
            ?: error("Wi-Fi changed; select the current network again")
        val value = actual + ("allow_wifi_roaming" to (selected["allow_wifi_roaming"] == true))
        prefs.edit().putString("policy", JSONObject(value).toString()).apply()
        refresh()
    }

    fun visible(value: Boolean) {
        visible = value
        if (value && !watching) {
            cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
            watching = true
        } else if (!value && watching) { cm.unregisterNetworkCallback(callback); watching = false }
        refresh()
    }

    private fun stopReceiver() {
        if (signature.isEmpty() && child == null) return
        signature = ""; generation++
        worker.execute {
            child?.let { p -> p.destroy(); if (!p.waitFor(3, TimeUnit.SECONDS)) p.destroyForcibly() }
            child = null
        }
        if (lock.isHeld) lock.release()
    }

    private fun refresh() {
        if (!visible || !initialized) { stopReceiver(); return }
        val policy = prefs.getString("policy", null)?.let { JSONObject(it) }
        val options = networks()
        val selected = options.firstOrNull { n ->
            policy != null && ((n["network_handle"] == policy.optString("network_handle") && (n["unmetered"] == true || !policy.optBoolean("unmetered"))) ||
                (policy.optBoolean("allow_wifi_roaming") && n["unmetered"] == true))
        }
        if (selected == null) {
            stopReceiver(); CoreRuntime.cancel()
            event(mapOf("state" to if (options.isEmpty()) "offline" else "approval_required", "network" to null)); return
        }
        val next = "${selected["network_handle"]}:${selected["interface"]}:${selected["cidr"]}"
        if (next == signature) return
        CoreRuntime.cancel()
        stopReceiver(); signature = next; val owner = ++generation
        if (!lock.isHeld) lock.acquire()
        event(mapOf("state" to "recovering", "network" to selected))
        worker.execute {
            try {
                if (owner != generation) return@execute
                val binary = File(context.applicationInfo.nativeLibraryDir, "libbridge_agent.so")
                check(binary.canExecute()) { "Bundled LAN agent unavailable" }
                val args = listOf(binary.path, "--state", File(context.filesDir, "devicebridge").path,
                    "--interface", selected["interface"] as String, "--lan-cidr", selected["cidr"] as String, "--port", "0")
                val builder = ProcessBuilder(args).redirectErrorStream(false)
                builder.environment()["DEVICEBRIDGE_NETWORK_HANDLE"] = selected["network_handle"] as String
                val process = builder.start(); child = process
                Thread {
                    process.inputStream.bufferedReader().use { reader ->
                        val line = reader.readLine()
                        if (line != null) {
                            val ready = JSONObject(line)
                            main.post { if (owner == generation) event(mapOf("state" to if(ready.optBoolean("discovery")) "active" else "receiver_error", "error" to ready.optString("discovery_error"), "network" to selected, "endpoint" to ready.optString("endpoint"), "device_id" to ready.optString("id"))) }
                        }
                        while (reader.readLine() != null) { /* drain, never log keys */ }
                    }
                }.start()
                Thread {
                    val error = process.errorStream.bufferedReader().use { reader ->
                        val tail = StringBuilder(); reader.forEachLine { tail.append(it.take(1024)); if (tail.length > 4096) tail.delete(0, tail.length - 4096) }; tail.toString()
                    }
                    val code = process.waitFor()
                    main.post { if (owner == generation) { signature = ""; event(mapOf("state" to "receiver_error", "network" to selected, "error" to "Listener stopped ($code). ${error.takeLast(1024)}")) } }
                }.start()
            } catch (e: Exception) { main.post { if (owner == generation) { signature = ""; event(mapOf("state" to "receiver_error", "network" to selected, "error" to e.message)) } } }
        }
    }
}
