package dev.devicebridge.devicebridge

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Own app node only. No VpnService, TUN, external daemon state or auth keys. */
class TailnetCoordinator(private val context: Context, private val networkChanged: () -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val prefs = context.getSharedPreferences("devicebridge-tailnet", Context.MODE_PRIVATE)
    private var visible = false
    private var transferring = false
    private var awaitingLogin = false
    private var proxyServiceActive = false
    private var proxyRetryDelay = 1_000L
    @Volatile private var network: Map<String, Any?>? = null
    private var extraNetwork: Map<String, Any?>? = null
    private var endpoint = ""
    private var upstream = ""
    private var signature = ""
    private var lastNetwork = ""
    @Volatile private var tsnetPrefs: Map<String, Any> = emptyMap()
    private var watching = false
    @Volatile private var child: Process? = null
    @Volatile private var generation = 0
    private val directory get() = File(context.filesDir, "devicebridge/tailnet")
    private val defaultNetwork = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = reconcile()
        override fun onLost(network: Network) = reconcile()
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = reconcile()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = reconcile()
    }
    private val delayedStop = Runnable {
        awaitingLogin = false
        reconcileNow()
    }
    private val loginTimeout = Runnable {
        awaitingLogin = false
        reconcile()
    }
    private val proxyRetry = Runnable {
        if (proxyServiceActive) reconcile()
    }

    fun enable(value: Boolean) {
        prefs.edit().putBoolean("enabled", value).apply()
        if (!value) {
            awaitingLogin = false
            main.removeCallbacks(delayedStop)
            main.removeCallbacks(loginTimeout)
            reconcile()
            return
        }
        reconcile()
    }

    fun awaitingLogin() {
        awaitingLogin = true
        main.removeCallbacks(delayedStop)
        main.removeCallbacks(loginTimeout)
        main.postDelayed(loginTimeout, 5 * 60_000L)
        reconcile()
    }

    fun visible(value: Boolean) {
        visible = value
        if (value) {
            main.removeCallbacks(delayedStop)
        }
        reconcile()
    }

    fun transferring(value: Boolean) {
        transferring = value
        if (value) {
            main.removeCallbacks(delayedStop)
        }
        reconcile()
    }

    fun proxyServiceActive(value: Boolean) {
        if (proxyServiceActive == value) return
        proxyServiceActive = value
        if (!value) {
            main.removeCallbacks(proxyRetry)
            proxyRetryDelay = 1_000L
        }
        reconcile()
    }

    fun network(value: Map<String, Any?>?, receiver: String = "", extraDirect: Map<String, Any?>? = null) {
        main.post {
            network = value
            endpoint = receiver
            extraNetwork = extraDirect
            reconcile()
        }
    }

    fun enabled() = prefs.getBoolean("enabled", false)

    fun isProcessRunning(): Boolean = child?.isAlive == true

    fun forceRestart() {
        stop()
        reconcile()
    }

    fun syncPrefs(config: Map<String, Any>) {
        tsnetPrefs = config
        worker.execute { pushPrefs(config) }
    }

    fun disableProxy() {
        syncPrefs(tsnetPrefs + ("socks5_enabled" to false))
    }

    fun detachScreen() {
        visible = false
        network = null
        extraNetwork = null
        if (!proxyServiceActive && !transferring && !awaitingLogin) {
            main.removeCallbacks(delayedStop)
            reconcileNow()
        } else {
            reconcile()
        }
    }

    private fun internetNetwork(): Map<String, Any?>? {
        val active = connectivity.activeNetwork ?: return null
        val capabilities = connectivity.getNetworkCapabilities(active) ?: return null
        if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return null
        val link = connectivity.getLinkProperties(active) ?: return null
        val iface = link.interfaceName ?: return null
        val address = link.linkAddresses.firstOrNull {
            !it.address.isLinkLocalAddress && !it.address.isLoopbackAddress
        } ?: return null
        return mapOf(
            "interface" to iface,
            "cidr" to "${address.address.hostAddress?.substringBefore('%')}/${address.prefixLength}",
            "network_handle" to active.networkHandle.toString(),
        )
    }

    fun pullNetwork(): Map<String, Any?> {
        val handle = (internetNetwork() ?: network)?.get("network_handle") as? String ?: return emptyMap()
        if (handle.isEmpty()) return emptyMap()
        val selected = connectivity.allNetworks.firstOrNull { it.networkHandle.toString() == handle } ?: return emptyMap()
        val caps = connectivity.getNetworkCapabilities(selected) ?: return emptyMap()
        val metered = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ||
            !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        return mapOf("tailnet_handle" to handle, "tailnet_cost" to if (metered) "metered" else "unmetered")
    }

    private fun control(target: String) {
        try {
            LocalSocket().use { socket ->
                socket.connect(LocalSocketAddress(File(directory, "control.sock").path, LocalSocketAddress.Namespace.FILESYSTEM))
                socket.soTimeout = 5000
                val line = JSONObject(mapOf("version" to 1, "operation" to "upstream", "target" to target)).toString() + "\n"
                socket.outputStream.write(line.toByteArray()); socket.outputStream.flush()
                socket.inputStream.bufferedReader().readLine()
            }
        } catch (_: Exception) { /* listener can become ready after this update; next active event retries */ }
    }

    private fun pushPrefs(config: Map<String, Any>) {
        if (config.isEmpty()) return
        try {
            LocalSocket().use { socket ->
                socket.connect(LocalSocketAddress(File(directory, "control.sock").path, LocalSocketAddress.Namespace.FILESYSTEM))
                socket.soTimeout = 5000
                val payload = HashMap<String, Any>(config)
                payload["version"] = 1
                payload["operation"] = "prefs"
                val line = JSONObject(payload).toString() + "\n"
                socket.outputStream.write(line.toByteArray()); socket.outputStream.flush()
                socket.inputStream.bufferedReader().readLine()
            }
        } catch (_: Exception) {}
    }

    private fun stop() {
        main.removeCallbacks(proxyRetry)
        generation++; signature = ""
        worker.execute {
            child?.let { p -> p.destroy(); if (!p.waitFor(5, TimeUnit.SECONDS)) { p.destroyForcibly(); p.waitFor(2, TimeUnit.SECONDS) } }
            child = null
        }
    }

    private fun processExited(owner: Int, startedAt: Long) {
        if (owner != generation) return
        signature = ""
        networkChanged()
        if (!proxyServiceActive || !enabled()) return
        if (SystemClock.elapsedRealtime() - startedAt >= 30_000L) proxyRetryDelay = 1_000L
        main.postDelayed(proxyRetry, proxyRetryDelay)
        proxyRetryDelay = (2 * proxyRetryDelay).coerceAtMost(60_000L)
    }

    private fun reconcile() {
        val needed = visible || transferring || awaitingLogin || proxyServiceActive
        val shouldWatch = enabled() && (needed || signature.isNotEmpty())
        if (shouldWatch != watching) {
            if (shouldWatch) connectivity.registerDefaultNetworkCallback(defaultNetwork, main)
            else connectivity.unregisterNetworkCallback(defaultNetwork)
            watching = shouldWatch
        }
        if (!enabled()) {
            main.removeCallbacks(delayedStop)
            reconcileNow()
            return
        }
        if (!needed) {
            // Keep tsnet alive briefly across app switches / SAF pickers / login return so state persists cleanly.
            main.removeCallbacks(delayedStop)
            main.postDelayed(delayedStop, 120_000L)
            return
        }
        main.removeCallbacks(delayedStop)
        reconcileNow()
    }

    private fun reconcileNow() {
        val selected = internetNetwork() ?: network
        val needed = visible || transferring || awaitingLogin || proxyServiceActive
        if (!enabled() || !needed || selected == null) {
            if (lastNetwork.isNotEmpty()) {
                lastNetwork = ""
                networkChanged()
            }
            if (signature.isNotEmpty()) stop()
            if (!needed && watching) {
                connectivity.unregisterNetworkCallback(defaultNetwork)
                watching = false
            }
            return
        }
        val handle = selected["network_handle"] as? String ?: ""
        val direct = extraNetwork?.takeIf { selected["interface"] != it["interface"] }
        val extraIface = direct?.get("interface") as? String ?: ""
        val extraCidr = direct?.get("cidr") as? String ?: ""
        val next = "$handle:${selected["cidr"]}:$extraIface:$extraCidr"
        if (next != lastNetwork) {
            lastNetwork = next
            networkChanged()
        }
        val target = endpoint
        if (signature == next) {
            if (upstream != target) {
                upstream = target
                worker.execute { control(target) }
            }
            return
        }
        stop(); signature = next; val owner = ++generation
        upstream = target
        worker.execute {
            val startedAt = SystemClock.elapsedRealtime()
            try {
                if (owner != generation) return@execute
                val binary = GoBinaryManager.resolve(context, "tailnet")
                check(binary.canExecute()) { "App-only Tailscale module is not installed" }
                if (GoBinaryManager.verboseEnabled(context)) {
                    android.util.Log.d("DeviceBridge.Tailnet", "start ${binary.path} cidr=${selected["cidr"]} iface=${selected["interface"]}")
                }
                val builder = ProcessBuilder(binary.path, "--state", directory.path, "--name", "termux")
                builder.environment()["DEVICEBRIDGE_NATIVE_LIB_DIR"] = context.applicationInfo.nativeLibraryDir
                builder.environment().apply {
                    if (handle.isNotEmpty()) {
                        put("DEVICEBRIDGE_NETWORK_HANDLE", handle)
                    } else {
                        remove("DEVICEBRIDGE_NETWORK_HANDLE")
                    }
                    put("DEVICEBRIDGE_LAN_CIDR", selected["cidr"] as String)
                    put("DEVICEBRIDGE_INTERFACE", selected["interface"] as String)
                    if (extraIface.isNotEmpty() && extraCidr.isNotEmpty()) {
                        put("DEVICEBRIDGE_EXTRA_INTERFACE", extraIface)
                        put("DEVICEBRIDGE_EXTRA_CIDR", extraCidr)
                    } else {
                        remove("DEVICEBRIDGE_EXTRA_INTERFACE")
                        remove("DEVICEBRIDGE_EXTRA_CIDR")
                    }
                    remove("TS_AUTHKEY"); remove("TS_CLIENT_SECRET")
                }
                val process = builder.start(); child = process
                Thread {
                    try {
                        process.inputStream.bufferedReader().use { reader ->
                            if (reader.readLine() != null) {
                                control(target)
                                pushPrefs(tsnetPrefs)
                                main.post { if (owner == generation) networkChanged() }
                            }
                            while (reader.readLine() != null) { /* drain, never print login URLs */ }
                        }
                    } catch (_: Exception) { /* stream closed during stop() */ }
                }.start()
                Thread {
                    try {
                        process.errorStream.bufferedReader().use { reader -> reader.forEachLine { /* never persist node logs/secrets */ } }
                    } catch (_: Exception) { /* stream closed during stop() */ }
                    try { process.waitFor() } catch (_: Exception) {}
                    main.post { processExited(owner, startedAt) }
                }.start()
            } catch (_: Exception) { main.post { processExited(owner, startedAt) } }
        }
    }
}
