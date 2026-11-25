package dev.devicebridge.devicebridge

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** Only a fixed, packaged executable; no shell and no privileged process. */
object CoreRuntime {
    @Volatile private var process: Process? = null
    @Volatile private var networkSensitive = false
    @Volatile private var fallbackAllowed = false
    @Volatile private var refreshPullLan: (() -> Unit)? = null
    @Volatile private var approvePullMetered: ((String) -> Boolean)? = null
    /** Handle and CIDR of a direct group this device joined as a station. */
    @Volatile var directNetworkProvider: (() -> Pair<String, String>?)? = null
    private val operationLock = Any()
    private val readers = Executors.newCachedThreadPool()
    fun cancel() { process?.let(::cancelProcess) }
    fun allowMeteredPull(id: String): Boolean = approvePullMetered?.invoke(id) == true
    fun refreshPullNetwork() { refreshPullLan?.invoke() }

    private fun cancelProcess(p: Process) {
        p.destroy()
        readers.submit {
            try {
                if (!p.waitFor(1200, java.util.concurrent.TimeUnit.MILLISECONDS)) {
                    p.destroyForcibly()
                }
            } catch (_: Exception) {
                p.destroyForcibly()
            }
        }
    }
    fun networkChanged() {
        refreshPullNetwork()
        if (networkSensitive && !fallbackAllowed) cancel()
    }

    fun execute(
        context: Context,
        arguments: List<String>,
        input: String,
        parallelProbe: Boolean = false,
        approvedPullLan: (() -> Map<String, Any?>?)? = null,
        pullTailnet: (() -> Map<String, Any?>)? = null,
        onProgress: ((Map<String, Any?>) -> Unit)? = null
    ): String = if (parallelProbe) {
        run(context, arguments, input, false)
    } else synchronized(operationLock) {
        run(context, arguments, input, true, approvedPullLan, pullTailnet, onProgress)
    }

    private fun run(
        context: Context,
        arguments: List<String>,
        input: String,
        track: Boolean,
        approvedPullLan: (() -> Map<String, Any?>?)? = null,
        pullTailnet: (() -> Map<String, Any?>)? = null,
        onProgress: ((Map<String, Any?>) -> Unit)? = null
    ): String {
        val binary = GoBinaryManager.resolve(context, "cli")
        check(binary.canExecute()) { "Bundled Go core is unavailable for this ABI" }
        if (GoBinaryManager.verboseEnabled(context)) {
            android.util.Log.d("DeviceBridge.Core", "cli exec ${binary.path} args=${arguments.joinToString(" ")}")
        }
        val wifi = context.getSystemService(WifiManager::class.java)
        val multicast = wifi.createMulticastLock("DeviceBridge discovery").apply { setReferenceCounted(false) }
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val cidrIndex = arguments.lastIndexOf("--lan-cidr")
        val cidr = if (cidrIndex >= 0 && cidrIndex + 1 < arguments.size) arguments[cidrIndex + 1] else null
        val keepOnNetworkChange = approvedPullLan != null || arguments.contains("--allow-route-fallback")
        val transportIndex = arguments.lastIndexOf("--transport")
        val transportMode = if (transportIndex >= 0 && transportIndex + 1 < arguments.size) arguments[transportIndex + 1] else "lan"
        val selectedWifi = if (cidr != null && transportMode == "lan") {
            cm.allNetworks.firstOrNull { network ->
                val caps = cm.getNetworkCapabilities(network)
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    cm.getLinkProperties(network)?.linkAddresses?.any { "${it.address.hostAddress}/${it.prefixLength}" == cidr } == true
            }
        } else null
        // A joined group is owned by this app's requestNetwork callback, so bind
        // it explicitly instead of relying on allNetworks enumeration order.
        val directHandle = directNetworkProvider?.invoke()?.takeIf { cidr != null && it.second == cidr }?.first
        val approvedHandle = selectedWifi?.networkHandle?.toString() ?: directHandle
        if (track && GoBinaryManager.verboseEnabled(context)) {
            android.util.Log.d("DeviceBridge.Core", "network cidr=$cidr transport=$transportMode handle=$approvedHandle")
        }
        if (track) {
            networkSensitive = approvedHandle != null
            fallbackAllowed = keepOnNetworkChange
        }
        val snapshot = if (approvedPullLan != null) {
            AtomicFile(File.createTempFile("devicebridge-pull-", ".json", context.cacheDir))
        } else null
        val manualLan = arguments.contains("--manual-lan-context")
        val snapshotLock = Any()
        var snapshotClosed = false
        var meteredApproved = false
        var lastSnapshot: Map<String, Any?>? = null
        val publishSnapshot: () -> Unit = {
            if (snapshot != null) synchronized(snapshotLock) {
                if (!snapshotClosed) {
                    val lan = if (manualLan) emptyMap() else approvedPullLan?.invoke().orEmpty()
                    val network = lan + pullTailnet?.invoke().orEmpty() + ("metered_approved" to meteredApproved)
                    if (network != lastSnapshot) {
                        val file = snapshot.startWrite()
                        try {
                            file.write(JSONObject(network).toString().toByteArray())
                            snapshot.finishWrite(file)
                            lastSnapshot = network
                        } catch (e: Exception) {
                            snapshot.failWrite(file)
                            throw e
                        }
                    }
                }
            }
        }
        fun refreshSnapshot() {
            try { publishSnapshot() } catch (e: Exception) {
                android.util.Log.w("DeviceBridge.Core", "Cannot update approved download network", e)
            }
        }
        var child: Process? = null
        val running = java.util.concurrent.atomic.AtomicReference<Process>()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { refreshSnapshot() }
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { refreshSnapshot() }
            override fun onLost(network: Network) {
                refreshSnapshot()
                if (!keepOnNetworkChange && network == selectedWifi) running.get()?.let(::cancelProcess)
            }
            override fun onLinkPropertiesChanged(network: Network, link: LinkProperties) {
                refreshSnapshot()
                if (!keepOnNetworkChange && network == selectedWifi && cidr != null && link.linkAddresses.none { "${it.address.hostAddress}/${it.prefixLength}" == cidr }) {
                    running.get()?.let(::cancelProcess)
                }
            }
        }
        val defaultCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { refreshSnapshot() }
            override fun onLost(network: Network) { refreshSnapshot() }
            override fun onLinkPropertiesChanged(network: Network, link: LinkProperties) { refreshSnapshot() }
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { refreshSnapshot() }
        }
        var watching = false
        var watchingDefault = false
        try {
            if (snapshot != null || approvedHandle != null) {
                multicast.acquire()
                cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
                watching = true
            }
            val policyArgs = if (snapshot != null) listOf("--require-pull-network-policy") else emptyList()
            val execFile = if (binary.exists()) binary else GoBinaryManager.resolve(context, "cli")
            val builder = ProcessBuilder(listOf(execFile.path) + policyArgs + arguments).redirectErrorStream(false)
            // Runs as this app's UID; no Termux, root or shared admin state.
            builder.environment()["DEVICEBRIDGE_SYNCTHING_BINARY"] = GoBinaryManager.resolve(context, "sync").absolutePath
            builder.environment()["TMPDIR"] = context.cacheDir.absolutePath
            val interfaceIndex = arguments.lastIndexOf("--interface")
            if (cidr != null && interfaceIndex >= 0 && interfaceIndex + 1 < arguments.size) {
                builder.environment()["DEVICEBRIDGE_SYNC_INTERFACE"] = arguments[interfaceIndex + 1]
                builder.environment()["DEVICEBRIDGE_SYNC_CIDR"] = cidr
            }
            if (snapshot != null) {
                publishSnapshot()
                refreshPullLan = ::refreshSnapshot
                approvePullMetered = { id ->
                    synchronized(snapshotLock) {
                        if (snapshotClosed || id != snapshot.baseFile.name) {
                            false
                        } else {
                            meteredApproved = true
                            try {
                                publishSnapshot()
                                true
                            } catch (e: Exception) {
                                meteredApproved = false
                                throw e
                            }
                        }
                    }
                }
                cm.registerDefaultNetworkCallback(defaultCallback)
                watchingDefault = true
                builder.environment()["DEVICEBRIDGE_PULL_LAN"] = snapshot.baseFile.path
            }
            if (approvedHandle != null) {
                builder.environment()["DEVICEBRIDGE_NETWORK_HANDLE"] = approvedHandle
            }
            val started = builder.start()
            child = started
            running.set(started)
            if (track) process = started
            val stdout = readers.submit<String> { started.inputStream.bufferedReader().use { it.readText() } }
            val stderr = readers.submit<String> {
                val tail = StringBuilder()
                try {
                    started.errorStream.bufferedReader().use { reader ->
                        reader.forEachLine { line ->
                            if (onProgress != null && line.startsWith("{")) {
                                try {
                                    val obj = JSONObject(line)
                                    if (obj.has("transfer_state")) {
                                        onProgress(mapOf(
                                            "transfer_state" to obj.optString("transfer_state"),
                                            "transport" to obj.optString("transport"),
                                            "endpoint" to obj.optString("endpoint"),
                                            "approval_id" to if (obj.optString("transfer_state") == "metered") snapshot?.baseFile?.name else null,
                                        ))
                                        return@forEachLine
                                    }
                                    if (obj.has("sent_bytes")) {
                                        onProgress(mapOf(
                                            "sent_bytes" to obj.optLong("sent_bytes"),
                                            "total_bytes" to obj.optLong("total_bytes"),
                                            "method" to "send-file",
                                        ))
                                        return@forEachLine
                                    }
                                    if (obj.has("verified_bytes")) {
                                        onProgress(mapOf(
                                            "file" to obj.optString("file"),
                                            "verified_bytes" to obj.optLong("verified_bytes"),
                                            "total_bytes" to obj.optLong("total_bytes"),
                                            "mib_per_second" to obj.optDouble("mib_per_second", 0.0),
                                            "elapsed_ms" to obj.optLong("elapsed_ms", 0L),
                                            "method" to obj.optString("method"),
                                            "transport" to obj.optString("transport"),
                                        ))
                                        return@forEachLine
                                    }
                                    if (obj.optBoolean("route_switched", false)) {
                                        onProgress(mapOf(
                                            "route_switched" to true,
                                            "from" to obj.optString("from"),
                                            "to" to obj.optString("to"),
                                            "endpoint" to obj.optString("endpoint"),
                                        ))
                                        return@forEachLine
                                    }
                                    if (obj.optBoolean("ssh_output", false)) {
                                        onProgress(mapOf(
                                            "ssh_output" to true,
                                            "stream" to obj.optString("stream"),
                                            "chunk" to obj.optString("chunk"),
                                        ))
                                        return@forEachLine
                                    }
                                } catch (_: Exception) { /* fall through to error tail */ }
                            }
                            if (tail.isNotEmpty()) tail.append('\n')
                            tail.append(line)
                            if (tail.length > 65536) tail.delete(0, tail.length - 65536)
                        }
                    }
                } catch (_: Exception) { /* stream closed during cancel() */ }
                tail.toString()
            }
            started.outputStream.bufferedWriter().use { it.write(input) }
            val code = started.waitFor()
            val out = stdout.get()
            val err = stderr.get()
            check(code == 0) { err.ifBlank { "Core exited with $code" } }
            return out
        } finally {
            running.set(null)
            child?.destroy()
            if (track) {
                refreshPullLan = null
                approvePullMetered = null
                process = null
                networkSensitive = false
                fallbackAllowed = false
            }
            if (watching) cm.unregisterNetworkCallback(callback)
            if (watchingDefault) cm.unregisterNetworkCallback(defaultCallback)
            if (snapshot != null) synchronized(snapshotLock) {
                snapshotClosed = true
                snapshot.delete()
            }
            if (multicast.isHeld) multicast.release()
        }
    }
}
