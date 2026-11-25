package dev.devicebridge.devicebridge

import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Permission opt-ins and execution-mode settings. Never assumes stale root grants. */
class DeviceSettings(private val context: Context, private val deliver: (() -> Unit) -> Unit) {
    private val prefs = context.getSharedPreferences("devicebridge-settings", Context.MODE_PRIVATE)
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    @Volatile private var lastRootCheckMs: Long = 0L
    @Volatile private var lastRootResult: Boolean = false
    private val permissionListener = Shizuku.OnRequestPermissionResultListener { code, grant ->
        if (code == 713) {
            prefs.edit().putBoolean("shizuku_enabled", grant == PackageManager.PERMISSION_GRANTED).apply()
            worker.execute {
                val snapshot = read()
                deliver {
                    pending?.success(snapshot)
                    pending = null
                }
            }
        }
    }

    init {
        Shizuku.addRequestPermissionResultListener(permissionListener)
    }

    fun close() {
        Shizuku.removeRequestPermissionResultListener(permissionListener)
        pending?.error("closed", "Settings closed before permission was returned", null)
        pending = null
        worker.shutdownNow()
    }

    private fun probeRootLive(timeoutSeconds: Long = 3L): Boolean {
        var child: Process? = null
        return try {
            child = ProcessBuilder("su", "-c", "id -u").start()
            if (!child.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
                false
            } else {
                val uid = child.inputStream.bufferedReader().use { it.readText().trim() }
                child.exitValue() == 0 && uid == "0"
            }
        } catch (_: Exception) {
            false
        } finally {
            child?.destroyForcibly()
        }
    }

    fun verifyRootEnabled(forceRefresh: Boolean = false): Boolean {
        if (!prefs.getBoolean("root_enabled", false)) {
            lastRootResult = false
            return false
        }
        val now = System.currentTimeMillis()
        if (!forceRefresh && lastRootCheckMs > 0 && (now - lastRootCheckMs) < 30_000L) {
            return lastRootResult
        }
        val ok = probeRootLive(3L)
        lastRootCheckMs = now
        lastRootResult = ok
        if (!ok) {
            prefs.edit()
                .putBoolean("root_enabled", false)
                .putString("root_status", "Root removed or denied (auto-disabled)")
                .apply()
        } else {
            prefs.edit().putString("root_status", "Permission verified · UID 0").apply()
        }
        return ok
    }

    fun startupSettings(): Map<String, Any?> = mapOf(
        "debug_mode" to prefs.getBoolean("debug_mode", true),
        "matte_items" to (prefs.getString("matte_items", "") ?: ""),
        "amoled_config" to (prefs.getString("amoled_config", "") ?: ""),
        "terminal_keyboard_config" to (
            prefs.getString("terminal_keyboard_config", null)
                ?: prefs.getString("termux_keyboard_config", "")
                ?: ""
        ),
    )

    fun isShizukuEnabledAndGranted(): Boolean {
        if (!prefs.getBoolean("shizuku_enabled", false)) return false
        val running = try { Shizuku.pingBinder() } catch (_: Exception) { false }
        if (!running) return false
        return try {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (_: Exception) {
            false
        }
    }

    fun read(): Map<String, Any?> {
        val running = try { Shizuku.pingBinder() } catch (_: Exception) { false }
        val shizukuGranted = running && try { Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED } catch (_: Exception) { false }
        val rootVerified = verifyRootEnabled(forceRefresh = true)
        val shizukuEnabled = prefs.getBoolean("shizuku_enabled", false) && shizukuGranted
        val shizukuUid = if (shizukuGranted) try { Shizuku.getUid() } catch (_: Exception) { -1 } else -1
        val executionMode = when {
            rootVerified -> "root"
            shizukuEnabled -> "shizuku"
            else -> "standard"
        }
        return mapOf(
            "android" to true,
            "keep_awake" to prefs.getBoolean("keep_awake", false),
            "show_hidden" to prefs.getBoolean("show_hidden", false),
            "verbose_logging" to prefs.getBoolean("verbose_logging", true),
            "execution_mode" to executionMode,
            "root_enabled" to rootVerified,
            "root_verified" to rootVerified,
            "root_status" to (prefs.getString("root_status", "Not requested") ?: "Not requested"),
            "root_feature_direct_link" to (rootVerified && prefs.getBoolean("root_feature_direct_link", true)),
            "root_feature_neighbors" to (rootVerified && prefs.getBoolean("root_feature_neighbors", true)),
            "root_feature_shell_diag" to (rootVerified && prefs.getBoolean("root_feature_shell_diag", false)),
            "root_feature_keep_terminal" to (rootVerified && prefs.getBoolean("root_feature_keep_terminal", false)),
            "shizuku_enabled" to shizukuEnabled,
            "shizuku_running" to running,
            "shizuku_uid" to shizukuUid,
            "shizuku_status" to if (!running) {
                "Service not running"
            } else if (shizukuGranted) {
                "Permission granted · ${if (shizukuUid == 0) "root" else "ADB shell"}"
            } else {
                "Permission required"
            },
            "shizuku_feature_direct_link" to (shizukuEnabled && prefs.getBoolean("shizuku_feature_direct_link", true)),
            "shizuku_feature_wifi_join" to (shizukuEnabled && prefs.getBoolean("shizuku_feature_wifi_join", true)),
            "tsnet_socks5_enabled" to prefs.getBoolean("tsnet_socks5_enabled", false),
            "tsnet_socks5_port" to prefs.getInt("tsnet_socks5_port", 1055).coerceIn(1024, 65535),
            "tsnet_exit_node_id" to (prefs.getString("tsnet_exit_node_id", "") ?: ""),
            "agent_enabled" to prefs.getBoolean("agent_enabled", true),
            "tsnet_ssh_enabled" to prefs.getBoolean("tsnet_ssh_enabled", true),
            "tsnet_openssh_enabled" to prefs.getBoolean("tsnet_openssh_enabled", false),
        ) + startupSettings()
    }

    fun tsnetConfig(): Map<String, Any> {
        return mapOf(
            "socks5_enabled" to prefs.getBoolean("tsnet_socks5_enabled", false),
            "socks5_port" to prefs.getInt("tsnet_socks5_port", 1055).coerceIn(1024, 65535),
            "exit_node_id" to (prefs.getString("tsnet_exit_node_id", "") ?: "").trim(),
            "tailscale_ssh_enabled" to prefs.getBoolean("tsnet_ssh_enabled", true),
            "openssh_enabled" to prefs.getBoolean("tsnet_openssh_enabled", false),
        )
    }

    fun rootDiagnosticsEnabled(): Boolean =
        prefs.getBoolean("root_feature_shell_diag", false) && verifyRootEnabled()

    fun detachedTerminalEnabled(): Boolean =
        prefs.getBoolean("root_feature_keep_terminal", false) && verifyRootEnabled(forceRefresh = true)

    fun update(values: Map<String, Any?>, result: MethodChannel.Result) {
        for ((key, value) in values) {
            val ok = when (key) {
                "matte_items" -> value is String && value.length <= 32768
                "amoled_config",
                "terminal_keyboard_config",
                "termux_keyboard_config" -> value is String && value.length <= 8192
                "tsnet_exit_node_id" -> value is String && value.length <= 1024
                "tsnet_socks5_port" -> value is Number && value.toInt() in 1024..65535
                "keep_awake",
                "show_hidden",
                "verbose_logging",
                "debug_mode",
                "root_enabled",
                "root_feature_direct_link",
                "root_feature_neighbors",
                "root_feature_shell_diag",
                "root_feature_keep_terminal",
                "shizuku_enabled",
                "shizuku_feature_direct_link",
                "shizuku_feature_wifi_join",
                "tsnet_socks5_enabled",
                "agent_enabled",
                "tsnet_ssh_enabled",
                "tsnet_openssh_enabled" -> value is Boolean
                else -> false
            }
            if (!ok) {
                result.error("invalid_setting", "Unknown setting or invalid value: $key", null)
                return
            }
        }
        if (values["root_enabled"] == false) {
            lastRootResult = false
            lastRootCheckMs = System.currentTimeMillis()
        }
        val tryingRootFeature = listOf(
            "root_feature_direct_link",
            "root_feature_neighbors",
            "root_feature_shell_diag",
            "root_feature_keep_terminal",
        ).any { values[it] == true }
        if (tryingRootFeature && values["root_enabled"] != true && !verifyRootEnabled(forceRefresh = false)) {
            result.error("root_disabled", "Enable Root access in Settings first", null)
            return
        }
        val tryingShizukuFeature = listOf(
            "shizuku_feature_direct_link",
            "shizuku_feature_wifi_join",
        ).any { values[it] == true }
        if (tryingShizukuFeature && values["shizuku_enabled"] != true && !isShizukuEnabledAndGranted()) {
            result.error("shizuku_disabled", "Enable Shizuku access in Settings first", null)
            return
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
                    lastRootCheckMs = System.currentTimeMillis()
                    lastRootResult = true
                    prefs.edit().putBoolean("root_enabled", true).putString("root_status", "Permission verified · UID 0").apply()
                    val snapshot = read()
                    deliver { pending?.success(snapshot); pending = null }
                } catch (e: Exception) {
                    lastRootCheckMs = System.currentTimeMillis()
                    lastRootResult = false
                    prefs.edit().putBoolean("root_enabled", false).putString("root_status", "Unavailable or denied").apply()
                    deliver { pending?.error("root_denied", e.message, null); pending = null }
                } finally {
                    child?.destroy()
                }
            }
            return
        }
        if (values["shizuku_enabled"] == true) {
            val running = try { Shizuku.pingBinder() } catch (_: Exception) { false }
            if (!running) {
                result.error("shizuku_stopped", "Start Shizuku, then enable access here", null)
                return
            }
            if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                if (Shizuku.shouldShowRequestPermissionRationale()) {
                    result.error("shizuku_denied", "Allow DeviceBridge in Shizuku's authorized applications", null)
                    return
                }
                pending = result
                try {
                    Shizuku.requestPermission(713)
                } catch (e: Exception) {
                    pending = null
                    result.error("shizuku_denied", e.message, null)
                }
                return
            }
        }
        val editor = prefs.edit()
        for ((key, value) in values) {
            when (key) {
                "matte_items", "amoled_config", "terminal_keyboard_config", "termux_keyboard_config", "tsnet_exit_node_id" ->
                    editor.putString(key, value as String)
                "tsnet_socks5_port" ->
                    editor.putInt(key, (value as Number).toInt().coerceIn(1024, 65535))
                else -> editor.putBoolean(key, value as Boolean)
            }
        }
        if (values["root_enabled"] == false) editor.putString("root_status", "Disabled in DeviceBridge")
        editor.apply()
        worker.execute {
            val snapshot = read()
            deliver { result.success(snapshot) }
        }
    }
}
