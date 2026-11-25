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
import android.provider.Settings
import org.json.JSONObject
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Foreground-only discovery/listener. Owns no system configuration or VPN. */
class LanCoordinator(
    private val context: Context,
    private val documentsEnvironment: () -> Map<String, String> = { emptyMap() },
    private val overlayEnabled: () -> Boolean = { false },
    private val event: (Map<String, Any?>) -> Unit
) {
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
    @Volatile private var directChild: Process? = null
    @Volatile private var directSig: String = ""
    @Volatile private var directGeneration = 0
    @Volatile private var currentState: String = "idle"
    @Volatile private var currentEndpoint: String = ""
    @Volatile private var currentSelected: Map<String, Any?>? = null
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { main.post { refresh() } }
        override fun onLost(network: Network) { main.post { refresh() } }
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) { main.post { refresh() } }
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { main.post { refresh() } }
    }

    fun networks(): List<Map<String, Any?>> {
        val list = cm.allNetworks.mapNotNull { network ->
            val caps = cm.getNetworkCapabilities(network) ?: return@mapNotNull null
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@mapNotNull null
            val link = cm.getLinkProperties(network) ?: return@mapNotNull null
            val address = link.linkAddresses.firstOrNull { it.address is Inet4Address && it.address.isSiteLocalAddress } ?: return@mapNotNull null
            mapOf("interface" to link.interfaceName, "cidr" to "${address.address.hostAddress}/${address.prefixLength}",
                "network_handle" to network.networkHandle.toString(), "unmetered" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
                "kind" to "wifi",
                "metered" to if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) "Unmetered Wi-Fi" else "Metered Wi-Fi: explicit approval required")
        }.toMutableList()
        // Detect local hotspot / Wi-Fi Direct group-owner interfaces that Android ConnectivityManager may not register as TRANSPORT_WIFI.
        try {
            val existing = list.map { "${it["interface"]}:${it["cidr"]}" }.toSet()
            val ifaces = NetworkInterface.getNetworkInterfaces()
            while (ifaces != null && ifaces.hasMoreElements()) {
                val iface = ifaces.nextElement()
                if (!iface.isUp || iface.isLoopback) continue
                val name = iface.name ?: continue
                if (!name.startsWith("ap") && !name.startsWith("swlan") && !name.startsWith("p2p") && !name.startsWith("wlan") && !name.startsWith("rndis") && !name.startsWith("usb") && !name.startsWith("eth")) continue
                for (la in iface.interfaceAddresses) {
                    val addr = la.address
                    if (addr is Inet4Address && addr.isSiteLocalAddress) {
                        val cidr = "${addr.hostAddress}/${la.networkPrefixLength}"
                        if ("$name:$cidr" !in existing) {
                            val kind = when {
                                name.startsWith("p2p") -> "wifi_direct"
                                name.startsWith("rndis") || name.startsWith("usb") || name.startsWith("eth") -> "usb_net"
                                name.startsWith("wlan") -> "wifi"
                                else -> "hotspot"
                            }
                            list.add(mapOf(
                                "interface" to name,
                                "cidr" to cidr,
                                "network_handle" to "",
                                "unmetered" to true,
                                "kind" to kind,
                                "metered" to "Hotspot / P2P local interface (explicit approval required)"
                            ))
                        }
                    }
                }
            }
        } catch (_: Exception) { /* restricted netlink on some Android builds */ }
        return list
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

    private fun isDirectSubInterface(iface: String, kind: String): Boolean {
        return kind == "hotspot" || kind == "wifi_direct" ||
            iface.startsWith("ap") || iface.startsWith("swlan") || iface.startsWith("p2p")
    }

    private fun isDirectSubInterface(obj: JSONObject): Boolean =
        isDirectSubInterface(obj.optString("interface"), obj.optString("kind"))

    fun approve(selected: Map<String, Any?>) {
        val reqHandle = selected["network_handle"] as? String
        val actual = networks().firstOrNull {
            (reqHandle.isNullOrEmpty() || it["network_handle"] == reqHandle) &&
            it["cidr"] == selected["cidr"] &&
            it["interface"] == selected["interface"]
        } ?: error("Network changed; select the current network again")
        // A joined direct group is a real ConnectivityManager Wi-Fi network on the
        // station interface, so remember that the peer hosts it: the policy then
        // survives Stop, the link keeps its direct label, and resumable pulls can
        // still bind to the Android network handle.
        val direct = selected["direct"] == true
        val value = actual + ("allow_wifi_roaming" to (selected["allow_wifi_roaming"] == true)) +
            if (direct) {
                mapOf("direct" to true, "kind" to (selected["kind"] as? String ?: "wifi_direct"))
            } else {
                emptyMap()
            }
        val nextObj = JSONObject(value)
        val editor = prefs.edit()
        if (isDirectSubInterface(nextObj)) {
            val prevStr = prefs.getString("policy", null)
            if (!prevStr.isNullOrBlank()) {
                try {
                    val prevObj = JSONObject(prevStr)
                    if (!isDirectSubInterface(prevObj)) {
                        editor.putString("prev_policy", prevStr)
                    }
                } catch (_: Exception) {}
            }
        } else {
            editor.remove("prev_policy")
        }
        editor.putString("policy", nextObj.toString()).apply()
        refresh()
    }

    fun restorePreviousPolicy() {
        val prevStr = prefs.getString("prev_policy", null)
        if (!prevStr.isNullOrBlank()) {
            prefs.edit().putString("policy", prevStr).remove("prev_policy").apply()
            refresh()
            return
        }
        val curStr = prefs.getString("policy", null)
        if (!curStr.isNullOrBlank()) {
            try {
                if (isDirectSubInterface(JSONObject(curStr))) {
                    prefs.edit().remove("policy").apply()
                    refresh()
                }
            } catch (_: Exception) {}
        }
    }

    fun refreshExports() { stopReceiver(); refresh() }
    fun refreshOverlays() { refresh() }

    fun forceRestart() {
        stopReceiver()
        stopDirectListener()
        refresh()
    }

    fun statusSnapshot(): Map<String, Any?> = mapOf(
        "running" to (child?.isAlive == true),
        "direct_running" to (directChild?.isAlive == true),
        "state" to currentState,
        "endpoint" to currentEndpoint,
        "network" to currentSelected,
        "direct_sig" to directSig,
    )

    fun allPhysicalInterfaces(): List<Map<String, Any?>> {
        val list = mutableListOf<Map<String, Any?>>()
        val seen = mutableSetOf<String>()
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            val link = cm.getLinkProperties(network) ?: continue
            val iface = link.interfaceName ?: continue
            val kind = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> {
                    // Ignore carrier IMS / VoLTE / MMS / XCAP signalling PDNs that stay up
                    // in the background even when Mobile Data is turned off.
                    if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                        !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED) ||
                        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_IMS)) {
                        continue
                    }
                    "cellular"
                }
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "usb_net"
                else -> continue
            }
            val addr = link.linkAddresses.firstOrNull {
                it.address is Inet4Address && !it.address.isLoopbackAddress
            } ?: link.linkAddresses.firstOrNull {
                !it.address.isLoopbackAddress && !it.address.isLinkLocalAddress
            }
            val cidr = if (addr != null) {
                "${addr.address.hostAddress?.substringBefore('%')}/${addr.prefixLength}"
            } else {
                ""
            }
            val key = "$kind:$iface:$cidr"
            if (!seen.add(key)) continue
            val unmetered = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            list.add(mapOf(
                "kind" to kind,
                "interface" to iface,
                "cidr" to cidr,
                "network_handle" to network.networkHandle.toString(),
                "unmetered" to unmetered,
                "has_internet" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                "connected" to true,
            ))
        }
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces()
            while (ifaces != null && ifaces.hasMoreElements()) {
                val iface = ifaces.nextElement()
                if (!iface.isUp || iface.isLoopback) continue
                val name = iface.name ?: continue
                val kind = when {
                    name.startsWith("p2p") -> "wifi_direct"
                    name.startsWith("ap") || name.startsWith("swlan") -> "hotspot"
                    name.startsWith("rndis") || name.startsWith("usb") || name.startsWith("eth") -> "usb_net"
                    else -> continue
                }
                for (la in iface.interfaceAddresses) {
                    val addr = la.address
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val cidr = "${addr.hostAddress}/${la.networkPrefixLength}"
                        val key = "$kind:$name:$cidr"
                        if (seen.add(key)) {
                            list.add(mapOf(
                                "kind" to kind,
                                "interface" to name,
                                "cidr" to cidr,
                                "network_handle" to "",
                                "unmetered" to true,
                                "has_internet" to false,
                                "connected" to true,
                            ))
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return list
    }

    @Synchronized
    fun startDirectListener(iface: String, cidr: String, port: Int = 8731) {
        if (!agentEnabled()) return
        val next = "$iface:$cidr:$port"
        if (next == directSig) return
        stopDirectListener()
        directSig = next
        val owner = directGeneration
        main.post { updateDiscoveryLock() }
        worker.execute {
            try {
                if (owner != directGeneration) return@execute
                val binary = GoBinaryManager.resolve(context, "agent")
                check(binary.canExecute()) { "Bundled direct-link agent unavailable" }
                if (GoBinaryManager.verboseEnabled(context)) {
                    android.util.Log.d("DeviceBridge.Lan", "startDirectListener ${binary.path} iface=$iface cidr=$cidr port=$port")
                }
                val args = listOf(binary.path, "--state", File(context.filesDir, "devicebridge").path,
                    "--interface", iface, "--lan-cidr", cidr, "--port", port.toString(), "--loopback-port", "-1")
                val builder = ProcessBuilder(args).redirectErrorStream(false)
                builder.environment().putAll(documentsEnvironment())
                builder.environment()["DEVICEBRIDGE_NATIVE_LIB_DIR"] = context.applicationInfo.nativeLibraryDir
                builder.environment()["DEVICEBRIDGE_DIRECT_AGENT"] = "1"
                builder.environment()["DEVICEBRIDGE_SYNC_INTERFACE"] = iface
                builder.environment()["DEVICEBRIDGE_SYNC_CIDR"] = cidr
                val p = builder.start()
                synchronized(this) {
                    if (owner != directGeneration) {
                        p.destroyForcibly()
                        return@execute
                    }
                    directChild = p
                }
                Thread { try { p.inputStream.bufferedReader().use { r -> while (r.readLine() != null) {} } } catch (_: Exception) {} }.start()
                Thread {
                    try { p.errorStream.bufferedReader().use { r -> while (r.readLine() != null) {} } } catch (_: Exception) {}
                    try { p.waitFor() } catch (_: Exception) {}
                    clearDirectListener(owner)
                }.start()
            } catch (_: Exception) {
                clearDirectListener(owner)
            }
        }
    }

    @Synchronized
    private fun clearDirectListener(owner: Int) {
        if (owner != directGeneration) return
        directSig = ""
        directChild = null
        main.post { updateDiscoveryLock() }
    }

    @Synchronized
    fun stopDirectListener() {
        directGeneration++
        directSig = ""
        main.post { updateDiscoveryLock() }
        val p = directChild ?: return
        directChild = null
        worker.execute {
            try { p.destroy(); if (!p.waitFor(2, TimeUnit.SECONDS)) p.destroyForcibly() } catch (_: Exception) {}
        }
    }

    fun visible(value: Boolean) {
        visible = value
        if (value && !watching) {
            cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
            watching = true
        } else if (!value && watching) { cm.unregisterNetworkCallback(callback); watching = false }
        refresh()
        updateDiscoveryLock()
    }

    private fun updateDiscoveryLock() {
        if (Looper.myLooper() != main.looper) {
            main.post { updateDiscoveryLock() }
            return
        }
        val discover = visible && (directSig.isNotEmpty() ||
            (signature.isNotEmpty() && signature != "app-loopback"))
        if (discover && !lock.isHeld) lock.acquire()
        if (!discover && lock.isHeld) lock.release()
    }

    private fun emitState(state: String, payload: Map<String, Any?>) {
        currentState = state
        currentEndpoint = payload["endpoint"] as? String ?: ""
        @Suppress("UNCHECKED_CAST")
        currentSelected = payload["network"] as? Map<String, Any?>
        event(payload)
    }

    private fun stopReceiver() {
        if (signature.isEmpty() && child == null) return
        signature = ""; generation++
        currentEndpoint = ""
        worker.execute {
            child?.let { p -> p.destroy(); if (!p.waitFor(3, TimeUnit.SECONDS)) p.destroyForcibly() }
            child = null
        }
        updateDiscoveryLock()
    }

    private fun matchPolicy(policy: JSONObject?, options: List<Map<String, Any?>>): Map<String, Any?>? {
        if (policy == null) return null
        val exact = options.firstOrNull { network ->
            val handle = network["network_handle"] as? String ?: ""
            handle == policy.optString("network_handle") &&
                network["cidr"] == policy.optString("cidr") &&
                network["interface"] == policy.optString("interface") &&
                (network["unmetered"] == true || !policy.optBoolean("unmetered"))
        }
        if (exact != null || !policy.optBoolean("allow_wifi_roaming")) return exact
        return defaultWifi(options)
    }

    private fun defaultWifi(options: List<Map<String, Any?>>): Map<String, Any?>? {
        val activeHandle = cm.activeNetwork?.networkHandle?.toString()
        val candidates = options.filter { network ->
            network["kind"] == "wifi" && network["unmetered"] == true &&
                !(network["network_handle"] as? String).isNullOrEmpty()
        }
        return candidates.firstOrNull { it["network_handle"] == activeHandle }
            ?: candidates.singleOrNull()
    }

    fun approvedPullLan(): Map<String, Any?>? {
        val options = networks().filter { it["kind"] == "wifi" }
        val policy = prefs.getString("policy", null)?.let(::JSONObject) ?: return defaultWifi(options)
        // A direct link hosted by the peer keeps this device on its station
        // interface, so it still owns a real Android network handle. Group-owner
        // interfaces have no handle and cannot be bound, so they stay excluded.
        if (isDirectSubInterface(policy) && policy.optString("network_handle").isBlank()) return null
        return matchPolicy(policy, options)
    }

    private fun agentEnabled(): Boolean = context.getSharedPreferences("devicebridge-settings", Context.MODE_PRIVATE).getBoolean("agent_enabled", true)

    // A replaced debug APK can leave its native child alive. Recover only the
    // recorded main Agent with this app UID and exact state argument. No root.
    private fun stopOrphanedMainAgent() {
        val state = File(context.filesDir, "devicebridge")
        val record = File(state, "agent-status.json")
        val pid = try { JSONObject(record.readText()).optInt("pid", -1) } catch (_: Exception) { -1 }
        if (pid <= 1 || pid == android.os.Process.myPid()) return
        val proc = File("/proc/$pid")
        val args = try { File(proc, "cmdline").readText().split('\u0000').filter { it.isNotEmpty() } } catch (_: Exception) { return }
        val index = args.indexOf("--state")
        if (index < 0 || args.getOrNull(index + 1) != state.path || File(args.firstOrNull() ?: "").name.let { it != "libbridge_agent.so" && !it.startsWith("agent_") }) return
        val uid = try { File(proc, "status").readLines().firstOrNull { it.startsWith("Uid:") }?.trim()?.split(Regex("\\s+"))?.getOrNull(1)?.toIntOrNull() } catch (_: Exception) { null }
        if (uid != android.os.Process.myUid()) return
        android.os.Process.sendSignal(pid, 15)
        val until = android.os.SystemClock.elapsedRealtime() + 2000
        while (android.os.SystemClock.elapsedRealtime() < until) {
            if (!File(proc, "cmdline").exists() || try { File(proc, "cmdline").length() == 0L && File(proc, "cmdline").readBytes().isEmpty() } catch (_: Exception) { true }) return
            Thread.sleep(25)
        }
        error("Previous DeviceBridge agent is still stopping")
    }

    private fun refresh() {
        if (!agentEnabled()) {
            stopReceiver(); stopDirectListener()
            worker.execute {
                try { stopOrphanedMainAgent() } catch (e: Exception) {
                    main.post { emitState("receiver_error", mapOf("state" to "receiver_error", "error" to "Agent is still stopping: ${e.message}")) }
                }
                main.post { emitState("disabled", mapOf("state" to "disabled")) }
            }
            currentState = "disabled"
            emitState("disabled", mapOf("state" to "disabled"))
            return
        }
        if (!visible || !initialized) { stopReceiver(); return }
        var policy = prefs.getString("policy", null)?.let { JSONObject(it) }
        val options = networks()
        var selected = matchPolicy(policy, options)
        if (selected == null && policy != null && isDirectSubInterface(policy)) {
            val prevStr = prefs.getString("prev_policy", null)
            if (!prevStr.isNullOrBlank()) {
                prefs.edit().putString("policy", prevStr).remove("prev_policy").apply()
                policy = JSONObject(prevStr)
                selected = matchPolicy(policy, options)
            } else {
                prefs.edit().remove("policy").apply()
                policy = null
            }
        }
        if (selected == null && policy == null) selected = defaultWifi(options)
        if (selected == null) {
            CoreRuntime.networkChanged()
            val offlineOrUnselected = if (options.isEmpty()) "offline" else "approval_required"
            emitState(offlineOrUnselected, mapOf("state" to offlineOrUnselected, "network" to null))
            val adbOn = try { Settings.Global.getInt(context.contentResolver, Settings.Global.ADB_ENABLED, 0) == 1 } catch (_: Exception) { false }
            if (!adbOn && !overlayEnabled()) {
                stopReceiver()
                return
            }
            val next = "app-loopback"
            if (next == signature) return
            stopReceiver(); signature = next; val owner = ++generation
            currentState = "loopback"
            currentEndpoint = "127.0.0.1:8731"
            worker.execute {
                try {
                    if (owner != generation) return@execute
                    val binary = GoBinaryManager.resolve(context, "agent")
                    if (!binary.canExecute()) return@execute
                    val args = listOf(binary.path, "--state", File(context.filesDir, "devicebridge").path,
                        "--interface", "lo", "--lan-cidr", "127.0.0.1/8", "--port", "8731", "--no-discovery")
                    val builder = ProcessBuilder(args).redirectErrorStream(false)
                    builder.environment().putAll(documentsEnvironment())
                    builder.environment()["DEVICEBRIDGE_NATIVE_LIB_DIR"] = context.applicationInfo.nativeLibraryDir
                    stopOrphanedMainAgent()
                    val process = builder.start(); child = process
                    Thread {
                        try { process.inputStream.bufferedReader().use { r -> while (r.readLine() != null) {} } } catch (_: Exception) {}
                    }.start()
                    Thread {
                        try { process.errorStream.bufferedReader().use { r -> while (r.readLine() != null) {} } } catch (_: Exception) {}
                        try { process.waitFor() } catch (_: Exception) {}
                        main.post { if (owner == generation) signature = "" }
                    }.start()
                } catch (_: Exception) { main.post { if (owner == generation) signature = "" } }
            }
            return
        }
        val handle = selected["network_handle"] as? String ?: ""
        val next = "$handle:${selected["interface"]}:${selected["cidr"]}"
        if (next == signature) return
        CoreRuntime.networkChanged()
        stopReceiver(); signature = next; val owner = ++generation
        updateDiscoveryLock()
        emitState("recovering", mapOf("state" to "recovering", "network" to selected))
        worker.execute {
            try {
                if (owner != generation) return@execute
                val binary = GoBinaryManager.resolve(context, "agent")
                check(binary.canExecute()) { "Bundled LAN agent unavailable" }
                if (GoBinaryManager.verboseEnabled(context)) {
                    android.util.Log.d("DeviceBridge.Lan", "start listener ${binary.path} iface=${selected["interface"]} cidr=${selected["cidr"]}")
                }
                val args = listOf(binary.path, "--state", File(context.filesDir, "devicebridge").path,
                    "--interface", selected["interface"] as String, "--lan-cidr", selected["cidr"] as String, "--port", "0", "--loopback-port", "8731")
                val builder = ProcessBuilder(args).redirectErrorStream(false)
                builder.environment().putAll(documentsEnvironment())
                builder.environment()["DEVICEBRIDGE_NATIVE_LIB_DIR"] = context.applicationInfo.nativeLibraryDir
                builder.environment()["DEVICEBRIDGE_SYNC_INTERFACE"] = selected["interface"] as String
                builder.environment()["DEVICEBRIDGE_SYNC_CIDR"] = selected["cidr"] as String
                if (handle.isNotEmpty()) {
                    builder.environment()["DEVICEBRIDGE_NETWORK_HANDLE"] = handle
                }
                stopOrphanedMainAgent()
                val process = builder.start(); child = process
                Thread {
                    try {
                        process.inputStream.bufferedReader().use { reader ->
                            val line = reader.readLine()
                            if (line != null) {
                                val ready = JSONObject(line)
                                main.post {
                                    if (owner == generation) {
                                        val st = if (ready.optBoolean("discovery")) "active" else "receiver_error"
                                        emitState(st, mapOf("state" to st, "error" to ready.optString("discovery_error"), "network" to selected, "endpoint" to ready.optString("endpoint"), "device_id" to ready.optString("id")))
                                    }
                                }
                            }
                            while (reader.readLine() != null) { /* drain, never log keys */ }
                        }
                    } catch (_: Exception) { /* stream closed during stopReceiver() */ }
                }.start()
                Thread {
                    val error = try {
                        process.errorStream.bufferedReader().use { reader ->
                            val tail = StringBuilder(); reader.forEachLine { tail.append(it.take(1024)); if (tail.length > 4096) tail.delete(0, tail.length - 4096) }; tail.toString()
                        }
                    } catch (_: Exception) { "" }
                    val code = try { process.waitFor() } catch (_: Exception) { -1 }
                    main.post { if (owner == generation) { signature = ""; updateDiscoveryLock(); emitState("receiver_error", mapOf("state" to "receiver_error", "network" to selected, "error" to "Listener stopped ($code). ${error.takeLast(1024)}")) } }
                }.start()
            } catch (e: Exception) { main.post { if (owner == generation) { signature = ""; updateDiscoveryLock(); emitState("receiver_error", mapOf("state" to "receiver_error", "network" to selected, "error" to e.message)) } } }
        }
    }
}
