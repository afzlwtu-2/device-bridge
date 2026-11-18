package dev.devicebridge.devicebridge

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import java.io.File
import java.util.concurrent.Executors

/** Only a fixed, packaged executable; no shell and no privileged process. */
object CoreRuntime {
    @Volatile private var process: Process? = null
    private val readers = Executors.newFixedThreadPool(2)
    fun cancel() { process?.destroy() }

    @Synchronized fun execute(context: Context, arguments: List<String>, input: String): String {
        val binary = File(context.applicationInfo.nativeLibraryDir, "libbridge_cli.so")
        check(binary.canExecute()) { "Bundled Go core is unavailable for this ABI" }
        val wifi = context.getSystemService(WifiManager::class.java)
        val multicast = wifi.createMulticastLock("DeviceBridge discovery").apply { setReferenceCounted(false) }
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val cidrIndex = arguments.indexOf("--lan-cidr")
        val cidr = if (cidrIndex >= 0) arguments[cidrIndex + 1] else null
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onLost(network: Network) { cancel() }
            override fun onLinkPropertiesChanged(network: Network, link: LinkProperties) {
                if (cidr != null && link.linkAddresses.none { "${it.address.hostAddress}/${it.prefixLength}" == cidr }) cancel()
            }
        }
        var watching = false
        try {
            if (cidr != null) {
                multicast.acquire()
                cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
                watching = true
            }
            val child = ProcessBuilder(listOf(binary.path) + arguments).redirectErrorStream(false).start()
            process = child
            val stdout = readers.submit<String> { child.inputStream.bufferedReader().use { it.readText() } }
            val stderr = readers.submit<String> { child.errorStream.bufferedReader().use { it.readText().takeLast(65536) } }
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
