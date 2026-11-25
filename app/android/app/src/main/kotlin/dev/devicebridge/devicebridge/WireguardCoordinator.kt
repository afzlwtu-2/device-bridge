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

/** Own app-only WireGuard tunnel (netstack userspace, never VpnService / system default route). */
class WireguardCoordinator(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val prefs = context.getSharedPreferences("devicebridge-wireguard", Context.MODE_PRIVATE)
    private var visible = false
    private var transferring = false
    private var network: Map<String, Any?>? = null
    private var endpoint = ""
    private var signature = ""
    private var child: Process? = null
    private var generation = 0
    private val stateDir get() = File(context.filesDir, "devicebridge")
    private val wgDir get() = File(stateDir, "wireguard")
    private val delayedStop = Runnable { reconcileNow() }

    fun enable(value: Boolean) {
        prefs.edit().putBoolean("enabled", value).apply()
        if (!value) {
            main.removeCallbacks(delayedStop)
            reconcileNow()
            return
        }
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

    fun network(value: Map<String, Any?>?, receiver: String = "") {
        if (value != null) {
            network = value
            endpoint = receiver
        } else {
            network = null
            endpoint = ""
        }
        reconcile()
    }

    fun enabled() = prefs.getBoolean("enabled", false) && File(wgDir, "config.json").exists()

    fun isProcessRunning(): Boolean = child?.isAlive == true

    fun forceRestart() {
        stop()
        reconcile()
    }

    private fun control(target: String) {
        try {
            LocalSocket().use { socket ->
                socket.connect(LocalSocketAddress(File(wgDir, "control.sock").path, LocalSocketAddress.Namespace.FILESYSTEM))
                socket.soTimeout = 5000
                val line = JSONObject(mapOf("version" to 1, "operation" to "upstream", "target" to target)).toString() + "\n"
                socket.outputStream.write(line.toByteArray()); socket.outputStream.flush()
                socket.inputStream.bufferedReader().readLine()
            }
        } catch (_: Exception) {}
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
        if (!enabled() || selected == null) {
            main.removeCallbacks(delayedStop)
            if (signature.isNotEmpty()) stop()
            return
        }
        if (!visible && !transferring) {
            main.removeCallbacks(delayedStop)
            main.postDelayed(delayedStop, 60_000L)
            return
        }
        main.removeCallbacks(delayedStop)
        reconcileNow()
    }

    private fun reconcileNow() {
        val selected = network
        if (!enabled() || (!visible && !transferring) || selected == null) {
            if (signature.isNotEmpty()) stop()
            return
        }
        val handle = selected["network_handle"] as? String ?: ""
        val next = "$handle:${selected["cidr"]}:${File(wgDir, "config.json").lastModified()}"
        if (signature == next) { worker.execute { control(endpoint) }; return }
        stop(); signature = next; val owner = ++generation
        val target = endpoint
        worker.execute {
            try {
                if (owner != generation) return@execute
                val binary = GoBinaryManager.resolve(context, "wg")
                check(binary.canExecute()) { "WireGuard module is not installed" }
                if (GoBinaryManager.verboseEnabled(context)) {
                    android.util.Log.d("DeviceBridge.Wg", "start ${binary.path} cidr=${selected["cidr"]} iface=${selected["interface"]}")
                }
                val builder = ProcessBuilder(binary.path, "--state", stateDir.path, "--backend", "userspace")
                builder.environment().apply {
                    if (handle.isNotEmpty()) {
                        put("DEVICEBRIDGE_NETWORK_HANDLE", handle)
                    } else {
                        remove("DEVICEBRIDGE_NETWORK_HANDLE")
                    }
                    put("DEVICEBRIDGE_LAN_CIDR", selected["cidr"] as String)
                    put("DEVICEBRIDGE_INTERFACE", selected["interface"] as String)
                }
                val process = builder.start(); child = process
                Thread {
                    try {
                        process.inputStream.bufferedReader().use { reader ->
                            if (reader.readLine() != null) control(target)
                            while (reader.readLine() != null) {}
                        }
                    } catch (_: Exception) {}
                }.start()
                Thread {
                    try { process.errorStream.bufferedReader().use { reader -> reader.forEachLine {} } } catch (_: Exception) {}
                    try { process.waitFor() } catch (_: Exception) {}
                    main.post { if (owner == generation) signature = "" }
                }.start()
            } catch (_: Exception) { main.post { if (owner == generation) signature = "" } }
        }
    }
}
