package dev.devicebridge.devicebridge

import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Permission opt-ins only. No privileged file server or system mutations. */
class DeviceSettings(private val context: Context, private val deliver: (() -> Unit) -> Unit) {
    private val prefs = context.getSharedPreferences("devicebridge-settings", Context.MODE_PRIVATE)
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private val permissionListener = Shizuku.OnRequestPermissionResultListener { code, grant ->
        if (code == 713) {
            prefs.edit().putBoolean("shizuku_enabled", grant == PackageManager.PERMISSION_GRANTED).apply()
            pending?.success(read()); pending = null
        }
    }
    init { Shizuku.addRequestPermissionResultListener(permissionListener) }
    fun close() {
        Shizuku.removeRequestPermissionResultListener(permissionListener)
        pending?.error("closed", "Settings closed before permission was returned", null)
        pending = null
        worker.shutdownNow()
    }
    fun read(): Map<String, Any> {
        val running = Shizuku.pingBinder()
        val granted = running && try { Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED } catch (_: Exception) { false }
        return mapOf(
            "android" to true,
            "keep_awake" to prefs.getBoolean("keep_awake", true),
            "show_hidden" to prefs.getBoolean("show_hidden", false),
            "matte_items" to (prefs.getString("matte_items", "") ?: ""),
            "root_enabled" to prefs.getBoolean("root_enabled", false),
            "root_status" to (prefs.getString("root_status", "Not requested") ?: "Not requested"),
            "shizuku_enabled" to (prefs.getBoolean("shizuku_enabled", false) && granted),
            "shizuku_running" to running,
            "shizuku_status" to if (!running) "Service not running" else if (granted) "Permission granted · ${if (Shizuku.getUid() == 0) "root" else "ADB shell"}" else "Permission required"
        )
    }
    fun update(values: Map<String, Any?>, result: MethodChannel.Result) {
        if (pending != null) { result.error("busy", "Finish the current permission request first", null); return }
        for ((key, value) in values) {
            val ok = when (key) {
                "matte_items" -> value is String && value.length <= 32768
                "keep_awake", "show_hidden", "root_enabled", "shizuku_enabled" -> value is Boolean
                else -> false
            }
            if (!ok) {
                result.error("invalid_setting", "Unknown setting or invalid value", null); return
            }
        }
        if (values["root_enabled"] == true) {
            pending = result
            worker.execute {
                var child: Process? = null
                try {
                    child = ProcessBuilder("su", "-c", "id -u").start()
                    check(child.waitFor(25, TimeUnit.SECONDS)) { "Root request timed out" }
                    val uid = child.inputStream.bufferedReader().use { it.readText().trim() }
                    check(child.exitValue() == 0 && uid == "0") { "Root permission was not granted" }
                    prefs.edit().putBoolean("root_enabled", true).putString("root_status", "Permission verified · UID 0").apply()
                    deliver { pending?.success(read()); pending = null }
                } catch (e: Exception) {
                    prefs.edit().putBoolean("root_enabled", false).putString("root_status", "Unavailable or denied").apply()
                    deliver { pending?.error("root_denied", e.message, null); pending = null }
                } finally { child?.destroy() }
            }
            return
        }
        if (values["shizuku_enabled"] == true) {
            if (!Shizuku.pingBinder()) { result.error("shizuku_stopped", "Start Shizuku, then enable access here", null); return }
            if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                if (Shizuku.shouldShowRequestPermissionRationale()) { result.error("shizuku_denied", "Allow DeviceBridge in Shizuku's authorized applications", null); return }
                pending = result
                try { Shizuku.requestPermission(713) } catch (e: Exception) { pending = null; result.error("shizuku_denied", e.message, null) }
                return
            }
        }
        val editor = prefs.edit()
        for ((key, value) in values) {
            if (key == "matte_items") editor.putString(key, value as String)
            else editor.putBoolean(key, value as Boolean)
        }
        if (values["root_enabled"] == false) editor.putString("root_status", "Disabled in DeviceBridge")
        editor.apply()
        result.success(read())
    }
}
