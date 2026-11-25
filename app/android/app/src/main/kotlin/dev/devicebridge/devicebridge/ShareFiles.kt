package dev.devicebridge.devicebridge

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Process
import android.provider.DocumentsContract as DC
import android.provider.OpenableColumns
import java.io.File
import java.io.IOException
import java.nio.file.Files

/** A share target hands Flutter a URI, then stages its content only after Send. */
internal class ShareFiles(private val context: Context) {
    private val limit = 64L * 1024 * 1024
    private val folderLimit = 1L shl 30

    companion object {
        fun validName(name: String): Boolean =
            name.isNotBlank() && name != "." && name != ".." &&
                !name.startsWith(".devicebridge-incoming-") &&
                !name.any { it == '/' || it == '\\' || it == '\u0000' || it == '\r' || it == '\n' } &&
                name.toByteArray(Charsets.UTF_8).size <= 255
    }

    private fun requireReadGrant(uri: Uri) {
        check(uri.scheme == "content") { "Choose an item using an Android document provider." }
        check(context.checkUriPermission(
            uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION
        ) == PackageManager.PERMISSION_GRANTED) {
            "Android did not grant access to this item. Choose it again."
        }
    }

    fun describe(uri: Uri): Map<String, Any?> {
        requireReadGrant(uri)
        var name: String? = null
        var size: Long? = null
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { rows ->
            if (rows.moveToFirst()) {
                val nameIndex = rows.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !rows.isNull(nameIndex)) name = rows.getString(nameIndex)
                val sizeIndex = rows.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !rows.isNull(sizeIndex)) size = rows.getLong(sizeIndex)
            }
        }
        val displayName = name ?: "shared-file"
        check(validName(displayName)) { "The file name cannot be shared." }
        check(size == null || size <= limit) { "Choose a file up to 64 MiB." }
        return mapOf("uri" to uri.toString(), "name" to displayName, "size" to size)
    }

    fun describeFolder(uri: Uri): Map<String, Any?> {
        requireReadGrant(uri)
        check(DC.isTreeUri(uri)) { "Choose a folder with the Android document picker." }
        val root = DC.buildDocumentUriUsingTree(uri, DC.getTreeDocumentId(uri))
        val name = context.contentResolver.query(root, arrayOf(DC.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { rows ->
            if (rows.moveToFirst()) rows.getString(0) else null
        } ?: error("The selected folder is unavailable.")
        check(validName(name)) { "The folder name cannot be shared." }
        return mapOf("uri" to uri.toString(), "name" to name, "directory" to true)
    }

    fun stageFolder(uri: Uri, checkActive: () -> Unit): String {
        val folder = describeFolder(uri)
        val directory = stagingDirectory()
        val staged = File(directory, folder["name"] as String)
        val resolver = context.contentResolver
        val visited = mutableSetOf<String>()
        val buffer = ByteArray(128 * 1024)
        var total = 0L
        var entries = 1
        val columns = arrayOf(
            DC.Document.COLUMN_DOCUMENT_ID, DC.Document.COLUMN_DISPLAY_NAME, DC.Document.COLUMN_MIME_TYPE
        )
        fun copy(id: String, dest: File, depth: Int) {
            check(depth <= 128 && visited.add(id) && dest.mkdir()) { "The selected folder could not be read safely." }
            val children = DC.buildChildDocumentsUriUsingTree(uri, id)
            val rows = resolver.query(children, columns, null, null, null)
                ?: error("Cannot list the selected folder.")
            rows.use {
                while (rows.moveToNext()) {
                    checkActive()
                    check(++entries <= 4096) { "Choose a folder with 4,096 entries or fewer." }
                    val childId = rows.getString(0)
                    val name = rows.getString(1)
                    check(validName(name)) { "The folder contains an invalid name." }
                    val target = File(dest, name)
                    if (rows.getString(2) == DC.Document.MIME_TYPE_DIR) {
                        copy(childId, target, depth + 1)
                        continue
                    }
                    check(target.createNewFile()) { "The folder contains duplicate names." }
                    val doc = DC.buildDocumentUriUsingTree(uri, childId)
                    val input = resolver.openInputStream(doc) ?: error("Cannot open ${target.name}.")
                    input.use { source ->
                        target.outputStream().use { output ->
                            while (true) {
                                checkActive()
                                val read = source.read(buffer)
                                if (read < 0) break
                                total += read
                                check(total <= folderLimit) { "Choose a folder up to 1 GiB." }
                                output.write(buffer, 0, read)
                            }
                        }
                    }
                }
            }
        }
        try {
            copy(DC.getTreeDocumentId(uri), staged, 0)
            checkActive()
            return staged.path
        } catch (error: Exception) {
            directory.deleteRecursively()
            throw error
        }
    }

    private fun stagingDirectory(): File {
        val parent = File(context.cacheDir, "devicebridge-share").apply { mkdirs() }
        return Files.createTempDirectory(parent.toPath(), "source-").toFile()
    }

    fun stage(uri: Uri, checkActive: () -> Unit): String {
        val file = describe(uri)
        val directory = stagingDirectory()
        val staged = File(directory, file["name"] as String)
        try {
            val input = context.contentResolver.openInputStream(uri) ?: error("Cannot open the selected file.")
            input.use { source ->
                staged.outputStream().use { output ->
                    val buffer = ByteArray(128 * 1024)
                    var total = 0L
                    while (true) {
                        checkActive()
                        val read = source.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > limit) throw IOException("Choose a file up to 64 MiB.")
                        output.write(buffer, 0, read)
                    }
                }
            }
            checkActive()
            return staged.path
        } catch (error: Exception) {
            directory.deleteRecursively()
            throw error
        }
    }
}
