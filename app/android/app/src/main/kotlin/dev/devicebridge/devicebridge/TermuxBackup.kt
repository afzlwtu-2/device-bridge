package dev.devicebridge.devicebridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FilterInputStream
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
    private var pendingSpec: String? = null
    private var progress: Map<String, Any?>? = null
    private var progressSink: EventChannel.EventSink? = null
    var restoring = false
        private set

    fun savedPackages(): String = prefs.getString("packages", "").orEmpty()

    fun observeProgress(sink: EventChannel.EventSink?) {
        progressSink = sink
        sink?.success(progress)
    }

    fun listEntries(subpath: String?, reply: MethodChannel.Result) {
        worker.execute {
            try {
                val context = activity.applicationContext
                val cli = GoBinaryManager.resolve(context, "cli")
                val state = File(context.filesDir, "devicebridge")
                val cmd = mutableListOf(cli.path, "--state", state.path, "termux-backup", "list")
                if (!subpath.isNullOrBlank()) {
                    cmd.add("--path")
                    cmd.add(subpath)
                }
                val proc = ProcessBuilder(cmd).redirectErrorStream(true).start()
                val out = proc.inputStream.bufferedReader().use { it.readText() }
                val code = proc.waitFor()
                if (code != 0) {
                    val msg = out.trim().ifBlank { "Unable to list Termux Home." }
                    activity.runOnUiThread { reply.error("termux_list_failed", msg, null) }
                    return@execute
                }
                val parsed = JSONObject(out)
                val entriesJson = parsed.optJSONArray("entries")
                val entries = mutableListOf<Map<String, Any>>()
                if (entriesJson != null) {
                    for (i in 0 until entriesJson.length()) {
                        val obj = entriesJson.getJSONObject(i)
                        entries.add(
                            mapOf(
                                "path" to obj.optString("path"),
                                "name" to obj.optString("name"),
                                "is_dir" to obj.optBoolean("is_dir"),
                                "size_bytes" to obj.optLong("size_bytes"),
                                "excluded_by_default" to obj.optBoolean("excluded_by_default"),
                                "always_included" to obj.optBoolean("always_included"),
                            )
                        )
                    }
                }
                val excludesJson = parsed.optJSONArray("default_excludes")
                val excludes = mutableListOf<String>()
                if (excludesJson != null) {
                    for (i in 0 until excludesJson.length()) {
                        excludes.add(excludesJson.getString(i))
                    }
                }
                val resultMap = mapOf("entries" to entries, "default_excludes" to excludes)
                activity.runOnUiThread { reply.success(resultMap) }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    reply.error("termux_list_failed", error.message ?: "Unable to list Termux Home.", null)
                }
            }
        }
    }

    fun pick(restore: Boolean, terminal: LocalTerminal, reply: MethodChannel.Result, specJson: String? = null) {
        if (pending != null) {
            reply.error("backup_busy", "A Termux backup operation is in progress.", null)
            return
        }
        pending = reply
        pendingSpec = specJson
        restoring = restore
        reportProgress(if (restore) "choose_backup" else "choose_destination")
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
        val spec = pendingSpec
        worker.execute {
            try {
                val result = runArchive(uri, restore, spec)
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

    private fun runArchive(uri: Uri, restore: Boolean, specJson: String? = null): Map<String, Any> {
        val context = activity.applicationContext
        val cli = GoBinaryManager.resolve(context, "cli")
        val state = File(context.filesDir, "devicebridge")
        val errors = File.createTempFile("termux-backup-", ".log", context.cacheDir)
        var process: Process? = null
        try {
            val cmd = mutableListOf(cli.path, "--state", state.path, "termux-backup", if (restore) "restore" else "create")
            if (!restore && !specJson.isNullOrBlank()) {
                cmd.add("--spec")
                cmd.add(specJson)
            }
            val child = ProcessBuilder(cmd)
                .redirectError(errors).start()
            process = child
            val resolver = context.contentResolver
            var written = 0L
            val response = if (!restore) {
                child.outputStream.close()
                child.inputStream.use { input ->
                    written = resolver.openOutputStream(uri, "w")?.use { out ->
                        track(input, "write") { it.copyTo(out, 128 * 1024) }
                    }
                        ?: error("Cannot write the selected backup.")
                }
                ""
            } else {
                val total = documentSize(uri)
                child.outputStream.use { out ->
                    readDocument(uri) { input -> track(input, "restore", total) { it.copyTo(out, 128 * 1024) } }
                }
                reportProgress("finish_restore")
                child.inputStream.bufferedReader().use { it.readText() }
            }
            val status = child.waitFor()
            val diagnostic = errors.readText().trim()
            if (status != 0) error(failureMessage(diagnostic))
            if (!restore) {
                val report = JSONObject(diagnostic)
                val actual = readDocument(uri) { track(it, "verify", written, checksum) }
                check(actual == report.getString("xxh64")) { "The saved backup failed XXH64 verification." }
                return mapOf(
                    "skipped" to report.getInt("skipped"),
                    "backed_up" to report.optInt("backed_up"),
                    "excluded" to report.optInt("excluded"),
                )
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

    private fun documentSize(uri: Uri): Long? = runCatching {
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getLong(0).takeIf { size -> size > 0 } else null
        }
    }.getOrNull()

    private fun <T> track(input: InputStream, phase: String, total: Long? = null, read: (InputStream) -> T): T {
        var bytes = 0L
        var lastUpdate = SystemClock.elapsedRealtime()
        fun advance(count: Int) {
            if (count <= 0) return
            bytes += count
            val now = SystemClock.elapsedRealtime()
            if (now - lastUpdate >= 250) {
                reportProgress(phase, bytes, total)
                lastUpdate = now
            }
        }
        reportProgress(phase, total = total)
        val monitored = object : FilterInputStream(input) {
            override fun read(): Int = super.read().also { if (it >= 0) advance(1) }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                super.read(buffer, offset, length).also(::advance)
        }
        return read(monitored).also { reportProgress(phase, bytes, total) }
    }

    private fun reportProgress(phase: String, bytes: Long = 0, total: Long? = null) {
        activity.runOnUiThread {
            progress = mapOf("phase" to phase, "bytes" to bytes, "total" to total)
            progressSink?.success(progress)
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
        pendingSpec = null
        restoring = false
        progress = null
        progressSink?.success(null)
        if (result != null) complete(result)
    }

    private companion object {
        const val REQUEST = 409
    }
}
