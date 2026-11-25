package dev.devicebridge.devicebridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

internal class TermuxBackup(
    private val activity: Activity,
    private val worker: Executor,
    private val checksum: (InputStream) -> String,
) {
    private val prefs = activity.getSharedPreferences("termux-backup", Activity.MODE_PRIVATE)
    private var pending: MethodChannel.Result? = null
    var restoring = false
        private set

    fun savedPackages(): String = prefs.getString("packages", "").orEmpty()

    fun pick(restore: Boolean, terminal: LocalTerminal, reply: MethodChannel.Result) {
        if (pending != null) {
            reply.error("backup_busy", "A Termux backup operation is in progress.", null)
            return
        }
        pending = reply
        restoring = restore
        if (restore) {
            terminal.hasSessions { active ->
                if (active) finish { it.error("termux_busy", "Close all Termux tabs before restoring.", null) }
                else openPicker(true)
            }
        } else openPicker(false)
    }

    private fun openPicker(restore: Boolean) {
        try {
            val intent = Intent(if (restore) Intent.ACTION_OPEN_DOCUMENT else Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType(if (restore) "*/*" else "application/gzip")
            if (!restore) {
                val stamp = java.time.LocalDateTime.now().format(java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss"))
                intent.putExtra(Intent.EXTRA_TITLE, "devicebridge-termux-$stamp.tar.gz")
            }
            activity.startActivityForResult(intent, REQUEST)
        } catch (error: Exception) {
            finish { it.error("backup_picker_failed", error.message, null) }
        }
    }

    fun handle(request: Int, resultCode: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false
        if (pending == null) return true
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            finish { it.success(null) }
            return true
        }
        val restore = restoring
        worker.execute {
            try {
                val result = runArchive(uri, restore)
                activity.runOnUiThread { finish { it.success(result) } }
            } catch (error: Exception) {
                Log.w("DeviceBridge.Backup", "Termux archive operation failed", error)
                if (!restore) runCatching { DocumentsContract.deleteDocument(activity.contentResolver, uri) }
                val message = error.message ?: "Termux archive failed (${error.javaClass.simpleName})."
                activity.runOnUiThread { finish { it.error("termux_backup_failed", message, null) } }
            }
        }
        return true
    }

    private fun runArchive(uri: Uri, restore: Boolean): Map<String, Any> {
        val context = activity.applicationContext
        val cli = File(context.applicationInfo.nativeLibraryDir, "libbridge_cli.so")
        val state = File(context.filesDir, "devicebridge")
        val errors = File.createTempFile("termux-backup-", ".log", context.cacheDir)
        var process: Process? = null
        try {
            val child = ProcessBuilder(cli.path, "--state", state.path, "termux-backup", if (restore) "restore" else "create")
                .redirectError(errors).start()
            process = child
            val resolver = context.contentResolver
            val response = if (restore) {
                child.outputStream.use { out ->
                    readDocument(uri) { it.copyTo(out, 128 * 1024) }
                }
                child.inputStream.bufferedReader().use { it.readText() }
            } else {
                child.outputStream.close()
                child.inputStream.use { input ->
                    resolver.openOutputStream(uri, "w")?.use { input.copyTo(it, 128 * 1024) }
                        ?: error("Cannot write the selected backup.")
                }
                ""
            }
            val status = child.waitFor()
            val diagnostic = errors.readText().trim()
            if (status != 0) error(failureMessage(diagnostic))
            if (!restore) {
                val report = JSONObject(diagnostic)
                val actual = readDocument(uri, checksum)
                check(actual == report.getString("xxh64")) { "The saved backup failed XXH64 verification." }
                return mapOf("skipped" to report.getInt("skipped"))
            }
            val info = JSONObject(response)
            val packages = info.getJSONArray("packages")
            val names = (0 until packages.length()).map { packages.getString(it) }
            prefs.edit().putString("packages", names.joinToString(" ")).apply()
            return mapOf("previous_home" to info.optString("previous_home"), "package_count" to names.size)
        } catch (error: Exception) {
            // A rejected archive can close stdin before Android finishes
            // copying it. Prefer the archive error over "broken pipe".
            if (process != null && process.waitFor(1, TimeUnit.SECONDS) && process.exitValue() != 0) {
                throw IllegalStateException(failureMessage(errors.readText().trim()), error)
            }
            throw error
        } finally {
            process?.destroy()
            errors.delete()
        }
    }

    private fun <T> readDocument(uri: Uri, read: (InputStream) -> T): T {
        val resolver = activity.contentResolver
        val input = try {
            resolver.openInputStream(uri)
        } catch (error: NullPointerException) {
            // Some ExternalStorageProvider builds fail when dispatching a
            // read-only open through MediaProvider. A granted read/write
            // descriptor opens the same document without truncating it.
            if (uri.authority != "com.android.externalstorage.documents") throw error
            resolver.openFileDescriptor(uri, "rw")?.let { ParcelFileDescriptor.AutoCloseInputStream(it) }
        } ?: error("Cannot read the backup document.")
        return input.use(read)
    }

    private fun failureMessage(diagnostic: String): String =
        runCatching { JSONObject(diagnostic).getString("message") }.getOrNull()
            ?: diagnostic.lineSequence().firstOrNull { it.isNotBlank() }?.take(400)
            ?: "Termux archive failed."

    private fun finish(complete: (MethodChannel.Result) -> Unit) {
        val result = pending
        pending = null
        restoring = false
        if (result != null) complete(result)
    }

    private companion object {
        const val REQUEST = 409
    }
}
