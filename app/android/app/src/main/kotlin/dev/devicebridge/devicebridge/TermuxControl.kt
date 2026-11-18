package dev.devicebridge.devicebridge

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** Local, explicitly requested Termux tools. This is never a peer-facing API. */
class TermuxControl(private val activity: Activity) {
    companion object { const val PERMISSION = "com.termux.permission.RUN_COMMAND"; const val REQUEST = 714; const val PREFIX = "/data/data/com.termux/files/usr/bin/" }
    private val handler = Handler(Looper.getMainLooper())
    private var permissionReply: MethodChannel.Result? = null
    private val active = mutableMapOf<String, Pair<BroadcastReceiver, PendingIntent>>()
    fun status() = mapOf("installed" to (activity.packageManager.getLaunchIntentForPackage("com.termux") != null), "permission" to (activity.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED), "home" to "/data/data/com.termux/files/home")
    fun permission(result: MethodChannel.Result) {
        if (activity.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED) { result.success(status()); return }
        if (permissionReply != null) { result.error("busy", "A Termux permission request is already open", null); return }
        permissionReply = result
        activity.requestPermissions(arrayOf(PERMISSION), REQUEST)
    }
    fun permissionResult(code: Int) {
        if (code == REQUEST) { permissionReply?.success(status()); permissionReply = null }
    }
    fun run(program: String, arguments: List<String>, result: MethodChannel.Result) {
        if (activity.checkSelfPermission(PERMISSION) != PackageManager.PERMISSION_GRANTED) { result.error("permission_required", "Grant the Run commands in Termux permission first", null); return }
        if (!program.matches(Regex("[A-Za-z0-9_.+-]+")) || program == "su" || arguments.size > 128 || arguments.sumOf { it.length } > 16384 || arguments.any { it.contains('\u0000') }) { result.error("invalid_command", "Choose an installed Termux tool and valid arguments", null); return }
        val action = "${activity.packageName}.TERMUX_RESULT.${UUID.randomUUID()}"
        val receiver = object: BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val registration = active.remove(action) ?: return
                try { activity.unregisterReceiver(registration.first) } catch (_: Exception) {}
                registration.second.cancel()
                val bundle = intent.getBundleExtra("result")
                if (bundle == null) { result.error("invalid_result", "Termux returned no result", null); return }
                val error = bundle.getString("errmsg", "") ?: ""
                if (bundle.getInt("err", -1) != -1) { result.error("termux_failed", error.ifBlank { "Enable allow-external-apps=true in Termux's ~/.termux/termux.properties" }, null); return }
                result.success(mapOf("stdout" to bundle.getString("stdout", ""), "stderr" to bundle.getString("stderr", ""), "exit_code" to bundle.getInt("exitCode", -1), "stdout_original_length" to bundle.getString("stdout_original_length", "")))
            }
        }
        val replyIntent = Intent(action).setPackage(activity.packageName)
        val flags = PendingIntent.FLAG_ONE_SHOT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val pending = PendingIntent.getBroadcast(activity, action.hashCode(), replyIntent, flags)
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(receiver, IntentFilter(action), Context.RECEIVER_NOT_EXPORTED) else @Suppress("DEPRECATION") activity.registerReceiver(receiver, IntentFilter(action))
        active[action] = Pair(receiver, pending)
        val intent = Intent("com.termux.RUN_COMMAND").setClassName("com.termux", "com.termux.app.RunCommandService")
            .putExtra("com.termux.RUN_COMMAND_PATH", PREFIX + "timeout")
            .putExtra("com.termux.RUN_COMMAND_ARGUMENTS", (listOf("--kill-after=3s", "60s", PREFIX + program) + arguments).toTypedArray())
            .putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home")
            .putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            .putExtra("com.termux.RUN_COMMAND_COMMAND_LABEL", "DeviceBridge: $program")
            .putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", pending)
        try { activity.startService(intent) }
        catch (e: Exception) { active.remove(action); activity.unregisterReceiver(receiver); pending.cancel(); result.error("termux_failed", e.message, null); return }
        handler.postDelayed({
            val registration = active.remove(action)
            if (registration != null) { try { activity.unregisterReceiver(registration.first) } catch (_: Exception) {}; registration.second.cancel(); result.error("termux_timeout", "Termux did not return a result. Check its external-apps setting and the Termux notification.", null) }
        }, 70000)
    }
    fun close() {
        for ((_, registration) in active) { try { activity.unregisterReceiver(registration.first) } catch (_: Exception) {}; registration.second.cancel() }
        active.clear(); permissionReply?.error("closed", "Permission request interrupted", null); permissionReply = null
    }
}
