package dev.devicebridge.devicebridge

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** Only a fixed, packaged executable; no shell and no privileged process. */
object CoreRuntime {
    @Volatile private var process: Process? = null
    private val readers = Executors.newFixedThreadPool(2)
    fun cancel() { process?.destroy() }

    @Synchronized fun execute(
        context: Context,
        arguments: List<String>,
        input: String,
        onProgress: ((Map<String, Any?>) -> Unit)? = null
    ): String {
        val binary = File(context.applicationInfo.nativeLibraryDir, "libbridge_cli.so")
        check(binary.canExecute()) { "Bundled Go core is unavailable for this ABI" }
        val wifi = context.getSystemService(WifiManager::class.java)
        val multicast = wifi.createMulticastLock("DeviceBridge discovery").apply { setReferenceCounted(false) }
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val cidrIndex = arguments.indexOf("--lan-cidr")
        val cidr = if (cidrIndex >= 0) arguments[cidrIndex + 1] else null
        val allowFallback = arguments.contains("--allow-route-fallback")
        val transportIndex = arguments.indexOf("--transport")
        val transportMode = if (transportIndex >= 0 && transportIndex + 1 < arguments.size) arguments[transportIndex + 1] else "lan"
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onLost(network: Network) { if (!allowFallback) cancel() }
            override fun onLinkPropertiesChanged(network: Network, link: LinkProperties) {
                if (!allowFallback && cidr != null && link.linkAddresses.none { "${it.address.hostAddress}/${it.prefixLength}" == cidr }) cancel()
            }
        }
        var watching = false
        try {
            if (cidr != null && transportMode == "lan") {
                multicast.acquire()
                cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
                watching = true
            }
            val builder = ProcessBuilder(listOf(binary.path) + arguments).redirectErrorStream(false)
            if (cidr != null && transportMode == "lan") {
                val selected = cm.allNetworks.firstOrNull { network ->
                    val caps = cm.getNetworkCapabilities(network)
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                        cm.getLinkProperties(network)?.linkAddresses?.any { "${it.address.hostAddress}/${it.prefixLength}" == cidr } == true
                }
                if (selected != null) {
                    builder.environment()["DEVICEBRIDGE_NETWORK_HANDLE"] = selected.networkHandle.toString()
                }
            }
            val child = builder.start()
            process = child
            val stdout = readers.submit<String> { child.inputStream.bufferedReader().use { it.readText() } }
            val stderr = readers.submit<String> {
                val tail = StringBuilder()
                child.errorStream.bufferedReader().use { reader ->
                    reader.forEachLine { line ->
                        if (onProgress != null && line.startsWith("{")) {
                            try {
                                val obj = JSONObject(line)
                                if (obj.has("verified_bytes")) {
                                    onProgress(mapOf(
                                        "file" to obj.optString("file"),
                                        "verified_bytes" to obj.optLong("verified_bytes"),
                                        "total_bytes" to obj.optLong("total_bytes"),
                                        "mib_per_second" to obj.optDouble("mib_per_second", 0.0),
                                        "elapsed_ms" to obj.optLong("elapsed_ms", 0L),
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
                            } catch (_: Exception) { /* fall through to error tail */ }
                        }
                        if (tail.isNotEmpty()) tail.append('\n')
                        tail.append(line)
                        if (tail.length > 65536) tail.delete(0, tail.length - 65536)
                    }
                }
                tail.toString()
            }
            child.outputStream.bufferedWriter().use { it.write(input) }
            val code = child.waitFor()
            val out = stdout.get()
            val err = stderr.get()
            check(code == 0) { err.ifBlank { "Core exited with $code" } }
            return out
        } finally {
            process?.destroy()
            process = null
            if (watching) cm.unregisterNetworkCallback(callback)
            if (multicast.isHeld) multicast.release()
        }
    }
}
