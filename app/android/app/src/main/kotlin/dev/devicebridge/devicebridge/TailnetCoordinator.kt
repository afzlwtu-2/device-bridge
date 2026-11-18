package dev.devicebridge.devicebridge

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Own app node only. No VpnService, TUN, external daemon state or auth keys. */
class TailnetCoordinator(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val prefs = context.getSharedPreferences("devicebridge-tailnet", Context.MODE_PRIVATE)
    private var visible = false
    private var transferring = false
    private var network: Map<String, Any?>? = null
    private var endpoint = ""
    private var signature = ""
    private var child: Process? = null
    private var generation = 0
    private val directory get() = File(context.filesDir, "devicebridge/tailnet")

    fun enable(value: Boolean) { prefs.edit().putBoolean("enabled", value).apply(); reconcile() }
    fun visible(value: Boolean) { visible = value; reconcile() }
    fun transferring(value: Boolean) { transferring = value; reconcile() }
    fun network(value: Map<String, Any?>?, receiver: String = "") { network = value; endpoint = receiver; reconcile() }
    fun enabled() = prefs.getBoolean("enabled", false)

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

    private fun stop() {
        generation++; signature = ""
        worker.execute {
            child?.let { p -> p.destroy(); if (!p.waitFor(5, TimeUnit.SECONDS)) { p.destroyForcibly(); p.waitFor(2, TimeUnit.SECONDS) } }
            child = null
        }
    }

    private fun reconcile() {
        val selected = network
        if (!enabled() || (!visible && !transferring) || selected == null) { if (signature.isNotEmpty()) stop(); return }
        val next = "${selected["network_handle"]}:${selected["cidr"]}"
        if (signature == next) { worker.execute { control(endpoint) }; return }
        stop(); signature = next; val owner = ++generation
        val target = endpoint
        worker.execute {
            try {
                if (owner != generation) return@execute
                val binary = File(context.applicationInfo.nativeLibraryDir, "libbridge_tailnet.so")
                check(binary.canExecute()) { "App-only Tailscale module is not installed" }
                val builder = ProcessBuilder(binary.path, "--state", directory.path, "--name", "devicebridge-phone")
                builder.environment().apply {
                    put("DEVICEBRIDGE_NETWORK_HANDLE", selected["network_handle"] as String)
                    put("DEVICEBRIDGE_LAN_CIDR", selected["cidr"] as String)
                    put("DEVICEBRIDGE_INTERFACE", selected["interface"] as String)
                    remove("TS_AUTHKEY"); remove("TS_CLIENT_SECRET")
                }
                val process = builder.start(); child = process
                Thread {
                    process.inputStream.bufferedReader().use { reader ->
                        if (reader.readLine() != null) control(target)
                        while (reader.readLine() != null) { /* drain, never print login URLs */ }
                    }
                }.start()
                Thread {
                    process.errorStream.bufferedReader().use { reader -> reader.forEachLine { /* never persist node logs/secrets */ } }
                    process.waitFor()
                    main.post { if (owner == generation) signature = "" }
                }.start()
            } catch (_: Exception) { main.post { if (owner == generation) signature = "" } }
        }
    }
}
