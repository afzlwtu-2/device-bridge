package dev.devicebridge.devicebridge

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.util.concurrent.TimeUnit

/** Audits Android runtime/special permissions across Standard, Shizuku, and Root modes. */
internal class PermissionManager(
    private val activity: Activity,
    private val deviceSettings: DeviceSettings,
) {
    companion object {
        const val REQUEST_PERMISSIONS = 410
    }

    private val prefs = activity.getSharedPreferences("devicebridge-settings", Context.MODE_PRIVATE)
    private var pendingReply: MethodChannel.Result? = null
    private var pendingPerms: List<String> = emptyList()
    private var pendingSpecialFallback: (() -> Unit)? = null
    private var autoGrantAttemptedForMode: String? = null

    private fun hasStoragePermission(): Boolean = hasAllFilesAccess(activity)

    private fun hasWifiNearbyPermissions(): Boolean {
        val fine = activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val nearby = activity.checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) == PackageManager.PERMISSION_GRANTED
            return fine && nearby
        }
        return fine
    }

    private fun hasNotificationPermission(): Boolean {
        val enabled = activity.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() != false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return enabled && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        }
        return enabled
    }

    private fun hasCameraPermission(): Boolean =
        activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun hasInstallPackagesPermission(): Boolean =
        activity.packageManager.canRequestPackageInstalls()

    fun status(autoGrantIfPrivileged: Boolean = false): Map<String, Any?> {
        deviceSettings.autoEnableShizukuIfAlreadyGranted()
        val rootOn = deviceSettings.verifyRootEnabled(forceRefresh = false)
        val shizukuRunning = try { Shizuku.pingBinder() } catch (_: Exception) { false }
        val shizukuGranted = shizukuRunning && try {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (_: Exception) { false }
        val shizukuOn = deviceSettings.isShizukuEnabledAndGranted()
        val mode = when {
            rootOn -> "root"
            shizukuOn -> "shizuku"
            else -> "standard"
        }
        if (autoGrantIfPrivileged && mode != "standard" && autoGrantAttemptedForMode != mode) {
            autoGrantAttemptedForMode = mode
            autoGrantPrivilegedPermissions(mode)
        }

        val storageOk = hasStoragePermission()
        val wifiOk = hasWifiNearbyPermissions()
        val notifOk = hasNotificationPermission()
        val cameraOk = hasCameraPermission()
        val installOk = hasInstallPackagesPermission()

        val items = mutableListOf(
            mapOf(
                "id" to "storage",
                "title" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    "Phone storage (All files access)"
                } else {
                    "Phone storage"
                },
                "description" to "Browse, share, transfer, and sync internal phone folders in File manager.",
                "granted" to storageOk,
                "required" to true,
                "kind" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) "special" else "runtime",
            ),
            mapOf(
                "id" to "wifi_nearby",
                "title" to "Wi-Fi & Nearby devices",
                "description" to if (mode == "standard") {
                    "Required in Standard mode for Hotspot, Wi-Fi Direct, and nearby discovery."
                } else {
                    "Granted for Android Wi-Fi & network diagnostics (covered by $mode mode for direct links)."
                },
                "granted" to wifiOk,
                "required" to (mode == "standard"),
                "kind" to "runtime",
            ),
            mapOf(
                "id" to "notifications",
                "title" to "Notifications",
                "description" to "Show active transfer, SOCKS5 proxy, and background service controls.",
                "granted" to notifOk,
                "required" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU),
                "kind" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) "runtime" else "special",
            ),
            mapOf(
                "id" to "camera",
                "title" to "Camera (QR pairing)",
                "description" to "Scan DeviceBridge pairing QR codes with the camera.",
                "granted" to cameraOk,
                "required" to false,
                "kind" to "runtime",
            ),
            mapOf(
                "id" to "install_packages",
                "title" to "Install app updates",
                "description" to "Optional for installing verified DeviceBridge releases in Standard mode.",
                "granted" to installOk,
                "required" to false,
                "kind" to "special",
            ),
        )
        val allEssential = items.all { (it["required"] != true) || (it["granted"] == true) }
        val allGranted = items.all { it["granted"] == true }
        val missingRuntime = missingRuntimePermissions()

        return mapOf(
            "execution_mode" to mode,
            "root_enabled" to rootOn,
            "shizuku_running" to shizukuRunning,
            "shizuku_granted" to shizukuGranted,
            "shizuku_enabled" to shizukuOn,
            "wizard_completed" to prefs.getBoolean("permissions_wizard_done", false),
            "all_essential_granted" to allEssential,
            "all_granted" to allGranted,
            "has_missing_runtime" to missingRuntime.isNotEmpty(),
            "permissions" to items,
        )
    }

    private fun missingRuntimePermissions(): List<String> {
        val missing = mutableListOf<String>()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            if (activity.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                missing.add(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
            if (activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                missing.add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            }
        }
        if (activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        if (activity.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.ACCESS_COARSE_LOCATION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (activity.checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED) {
                missing.add(Manifest.permission.NEARBY_WIFI_DEVICES)
            }
            if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                missing.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.CAMERA)
        }
        return missing.distinct()
    }

    fun autoGrantPrivilegedPermissions(preferredMode: String? = null): Boolean {
        val rootOk = if (preferredMode == "shizuku") false else deviceSettings.verifyRootEnabled(forceRefresh = false)
        val shizukuOk = if (rootOk) false else deviceSettings.isShizukuEnabledAndGranted()
        if (!rootOk && !shizukuOk) return false

        val pkg = activity.packageName
        val commands = mutableListOf<String>()
        for (perm in missingRuntimePermissions()) {
            commands.add("pm grant $pkg $perm >/dev/null 2>&1 || true")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !hasStoragePermission()) {
            commands.add("(cmd appops set $pkg MANAGE_EXTERNAL_STORAGE allow || appops set $pkg MANAGE_EXTERNAL_STORAGE allow) >/dev/null 2>&1 || true")
        }
        if (!hasInstallPackagesPermission()) {
            commands.add("(cmd appops set $pkg REQUEST_INSTALL_PACKAGES allow || appops set $pkg REQUEST_INSTALL_PACKAGES allow) >/dev/null 2>&1 || true")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !hasNotificationPermission()) {
            commands.add("(cmd appops set $pkg POST_NOTIFICATION allow || appops set $pkg POST_NOTIFICATION allow) >/dev/null 2>&1 || true")
        }
        if (commands.isEmpty()) return true

        val script = commands.joinToString("; ")
        return try {
            val proc: Process = if (rootOk) {
                ProcessBuilder("su", "-c", script).redirectErrorStream(true).start()
            } else {
                val method = Shizuku::class.java.getDeclaredMethod(
                    "newProcess",
                    Array<String>::class.java,
                    Array<String>::class.java,
                    String::class.java,
                )
                method.isAccessible = true
                method.invoke(null, arrayOf("sh", "-c", script), null, null) as Process
            }
            try {
                proc.waitFor(10, TimeUnit.SECONDS)
            } finally {
                if (proc.isAlive) proc.destroyForcibly()
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    fun request(id: String, reply: MethodChannel.Result) {
        if (pendingReply != null) {
            reply.error("busy", "Another permission request is already open.", null)
            return
        }
        when (id) {
            "storage" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    if (!hasStoragePermission()) openAllFilesAccessSettings()
                    reply.success(status())
                } else {
                    requestRuntimeList(
                        listOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
                        reply,
                        ::openAppDetailsSettings,
                    )
                }
            }
            "wifi_nearby" -> {
                val list = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    list.add(Manifest.permission.NEARBY_WIFI_DEVICES)
                }
                requestRuntimeList(list, reply, ::openAppDetailsSettings)
            }
            "notifications" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    requestRuntimeList(listOf(Manifest.permission.POST_NOTIFICATIONS), reply, ::openNotificationSettings)
                } else {
                    if (!hasNotificationPermission()) openNotificationSettings()
                    reply.success(status())
                }
            }
            "camera" -> {
                requestRuntimeList(listOf(Manifest.permission.CAMERA), reply, ::openAppDetailsSettings)
            }
            "install_packages" -> {
                if (!hasInstallPackagesPermission()) openInstallPackagesSettings()
                reply.success(status())
            }
            "runtime_batch" -> {
                val missing = missingRuntimePermissions()
                if (missing.isEmpty()) {
                    reply.success(status())
                } else {
                    requestRuntimeList(missing, reply, ::openAppDetailsSettings)
                }
            }
            else -> reply.error("unknown_permission", "Unknown permission: $id", null)
        }
    }

    private fun requestRuntimeList(perms: List<String>, reply: MethodChannel.Result, fallback: () -> Unit) {
        val missing = perms.filter { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            reply.success(status())
            return
        }
        pendingReply = reply
        pendingPerms = missing
        pendingSpecialFallback = fallback
        activity.requestPermissions(missing.toTypedArray(), REQUEST_PERMISSIONS)
    }

    fun handlePermissionResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_PERMISSIONS) return false
        val reply = pendingReply ?: return true
        val perms = pendingPerms
        val fallback = pendingSpecialFallback
        pendingReply = null
        pendingPerms = emptyList()
        pendingSpecialFallback = null

        val stillDenied = perms.filter { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (stillDenied.isNotEmpty() && stillDenied.none { activity.shouldShowRequestPermissionRationale(it) }) {
            // User permanently denied or OS blocked runtime prompt; open the exact Android settings page.
            fallback?.invoke()
        }
        reply.success(status())
        return true
    }

    private fun launchFirst(intents: List<Intent>) {
        for (intent in intents) {
            try {
                if (intent.resolveActivity(activity.packageManager) != null) {
                    activity.startActivity(intent)
                    return
                }
            } catch (_: Exception) {}
        }
    }

    private fun openAllFilesAccessSettings() {
        val pkgUri = Uri.parse("package:${activity.packageName}")
        val intents = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            intents.add(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, pkgUri))
            intents.add(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
        intents.add(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkgUri))
        launchFirst(intents)
    }

    private fun openInstallPackagesSettings() {
        val pkgUri = Uri.parse("package:${activity.packageName}")
        launchFirst(
            listOf(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, pkgUri),
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkgUri),
            ),
        )
    }

    private fun openNotificationSettings() {
        val pkgUri = Uri.parse("package:${activity.packageName}")
        launchFirst(
            listOf(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName),
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkgUri),
            ),
        )
    }

    private fun openAppDetailsSettings() {
        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}")))
    }

    fun close() {
        pendingReply?.error("closed", "Permission request interrupted", null)
        pendingReply = null
        pendingPerms = emptyList()
        pendingSpecialFallback = null
    }
}
