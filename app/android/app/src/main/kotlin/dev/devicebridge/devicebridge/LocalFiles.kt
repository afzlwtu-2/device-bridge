package dev.devicebridge.devicebridge

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract as DC
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File
import java.io.InputStream
import java.io.FileOutputStream
import java.util.UUID

/** The local phone has three independent, permission-scoped storage providers. */
class LocalFiles(private val activity: Activity, private val checksum: (InputStream) -> String) {
    private val resolver get() = activity.contentResolver
    private val prefs = activity.getSharedPreferences("devicebridge-targets", Activity.MODE_PRIVATE)
    data class Ref(val kind: String, val path: String)
    data class Node(val relative: String, val ref: Ref, val entry: Map<String, Any?>)
    private fun clean(value: String): String {
        if (value == "." || value.isEmpty()) return ""
        check(!value.startsWith('/') && !value.contains('\\') && !value.contains('\u0000') && value.split('/').none { it.isEmpty() || it == "." || it == ".." }) { "Unsafe relative path" }
        return value
    }
    private fun ref(map: Map<*, *>): Ref {
        val kind = map["kind"] as? String ?: error("Storage kind required")
        check(kind in setOf("internal", "saf", "termux", "downloads")) { "Unknown storage provider" }
        return Ref(kind, clean(map["path"] as? String ?: ""))
    }
    private fun join(a: String, b: String) = if (a.isEmpty()) b else "$a/$b"
    private fun internal(ref: Ref): File {
        if (ref.kind != "downloads") check(Environment.isExternalStorageManager()) { "Grant phone storage access first" }
        val root = if (ref.kind == "downloads") File(activity.filesDir, "devicebridge/downloads").canonicalFile else Environment.getExternalStorageDirectory().canonicalFile
        val candidate = if (ref.path.isEmpty()) root else File(root, ref.path)
        check(candidate.canonicalPath == candidate.absolutePath && (candidate == root || candidate.path.startsWith(root.path + File.separator))) { "Symlinks or storage escape rejected" }
        return candidate
    }
    private val documentCache = mutableMapOf<Ref, Uri>()
    private var termuxCanonicalRoot: String? = null
    private fun tree(kind: String): Uri {
        val raw = prefs.getString(if (kind == "termux") "termux_uri" else "saf_uri", null) ?: error(if (kind == "termux") "Grant Termux Home first" else "Choose an SAF folder first")
        val uri = Uri.parse(raw)
        if (kind == "termux") check(uri.authority == "com.termux.documents") { "Choose Termux Home from the system picker" }
        check(resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }) { "Storage grant expired; choose the folder again" }
        return uri
    }
    private fun children(parent: Uri): List<Map<String, Any?>> {
        val childUri = DC.buildChildDocumentsUriUsingTree(parent, DC.getDocumentId(parent))
        val columns = arrayOf(DC.Document.COLUMN_DOCUMENT_ID, DC.Document.COLUMN_DISPLAY_NAME, DC.Document.COLUMN_MIME_TYPE, DC.Document.COLUMN_SIZE, DC.Document.COLUMN_LAST_MODIFIED)
        val result = mutableListOf<Map<String, Any?>>()
        resolver.query(childUri, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1) ?: continue
                check(clean(name).isNotEmpty() && !name.contains('/')) { "Invalid destination name" }
                result.add(mapOf("name" to name, "kind" to if (cursor.getString(2) == DC.Document.MIME_TYPE_DIR) "directory" else "file", "size" to cursor.getLong(3), "modified" to cursor.getLong(4), "uri" to DC.buildDocumentUriUsingTree(parent, cursor.getString(0)).toString()))
            }
        } ?: error("Cannot enumerate this document provider")
        check(result.map { it["name"] }.distinct().size == result.size) { "Duplicate document names are ambiguous" }
        return result.sortedWith(compareBy<Map<String, Any?>> { if (it["kind"] == "directory") 0 else 1 }.thenBy { (it["name"] as String).lowercase() })
    }
    private fun checkTermuxDocument(uri: Uri, relative: String) {
        val canonicalRoot = termuxCanonicalRoot ?: run {
            val root = tree("termux")
            val rootDocument = DC.buildDocumentUriUsingTree(root, DC.getTreeDocumentId(root))
            val path = resolver.openFileDescriptor(rootDocument, "r")!!.use { android.system.Os.readlink("/proc/self/fd/${it.fd}") }
            termuxCanonicalRoot = path
            path
        }
        resolver.openFileDescriptor(uri, "r")!!.use {
            val actual = android.system.Os.readlink("/proc/self/fd/${it.fd}")
            val expected = if (relative.isEmpty()) canonicalRoot else "$canonicalRoot/$relative"
            check(actual == expected) { "Termux symlink or grant escape rejected" }
        }
    }
    private fun document(ref: Ref): Uri {
        documentCache[ref]?.let { cached -> if (ref.kind == "termux") checkTermuxDocument(cached, ref.path); return cached }
        val root = tree(ref.kind)
        var current = DC.buildDocumentUriUsingTree(root, DC.getTreeDocumentId(root))
        var relative = ""
        if (ref.kind == "termux") checkTermuxDocument(current, relative)
        if (ref.path.isNotEmpty()) for (part in ref.path.split('/')) {
            current = Uri.parse(children(current).singleOrNull { it["name"] == part }?.get("uri") as? String ?: error("Document no longer exists: $part"))
            relative = join(relative, part)
            if (ref.kind == "termux") checkTermuxDocument(current, relative)
        }
        documentCache[ref] = current
        return current
    }
    fun roots(): List<Map<String, Any?>> {
        fun granted(kind: String) = try { tree(kind); true } catch (_: Exception) { false }
        val result = mutableListOf<Map<String, Any?>>(mapOf("id" to "internal", "name" to "Internal storage", "available" to Environment.isExternalStorageManager()), mapOf("id" to "saf", "name" to "SAF", "available" to granted("saf")))
        if (activity.packageManager.getLaunchIntentForPackage("com.termux") != null) result.add(mapOf("id" to "termux", "name" to "Termux Home", "available" to granted("termux")))
        return result
    }
    fun list(ref: Ref): List<Map<String, Any?>> {
        if (ref.kind == "internal" || ref.kind == "downloads") return (internal(ref).listFiles() ?: error("Folder cannot be read")).mapNotNull { file ->
            try { val child = Ref(ref.kind, join(ref.path, file.name)); val checked = internal(child); if (!checked.isFile && !checked.isDirectory) null else mapOf("name" to checked.name, "path" to child.path, "kind" to if (checked.isDirectory) "directory" else "file", "size" to checked.length(), "modified" to checked.lastModified()) } catch (_: Exception) { null }
        }.sortedWith(compareBy<Map<String, Any?>> { if (it["kind"] == "directory") 0 else 1 }.thenBy { (it["name"] as String).lowercase() })
        return children(document(ref)).map {
            val path = join(ref.path, it["name"] as String)
            documentCache[Ref(ref.kind, path)] = Uri.parse(it["uri"] as String)
            it + ("path" to path) - "uri"
        }
    }
    fun stat(ref: Ref): Map<String, Any?> {
        if (ref.kind == "internal" || ref.kind == "downloads") { val f = internal(ref); check(f.exists()) { "Source no longer exists" }; return mapOf("name" to f.name, "kind" to if (f.isDirectory) "directory" else "file", "size" to f.length()) }
        val uri = document(ref)
        resolver.query(uri, arrayOf(DC.Document.COLUMN_DISPLAY_NAME, DC.Document.COLUMN_MIME_TYPE, DC.Document.COLUMN_SIZE), null, null, null)?.use { cursor ->
            check(cursor.moveToFirst()) { "Source no longer exists" }
            return mapOf("name" to cursor.getString(0), "kind" to if (cursor.getString(1) == DC.Document.MIME_TYPE_DIR) "directory" else "file", "size" to cursor.getLong(2))
        }
        error("Cannot inspect source")
    }
    fun read(ref: Ref): InputStream = if (ref.kind == "internal" || ref.kind == "downloads") internal(ref).inputStream() else resolver.openInputStream(document(ref)) ?: error("Cannot open document")
    private fun delete(ref: Ref) {
        check(ref.path.isNotEmpty()) { "A storage root cannot be moved" }
        if (ref.kind == "internal" || ref.kind == "downloads") check(internal(ref).delete()) { "Cannot remove verified source" }
        else check(DC.deleteDocument(resolver, document(ref))) { "Cannot remove verified source document" }
    }
    private fun runCore(arguments: List<String>): String {
        val binary = File(activity.applicationInfo.nativeLibraryDir, "libbridge_cli.so")
        val child = ProcessBuilder(listOf(binary.path, "--state", File(activity.filesDir, "devicebridge").path) + arguments).start()
        try {
            child.outputStream.close()
            val output = child.inputStream.bufferedReader().use { it.readText() }
            val error = child.errorStream.bufferedReader().use { it.readText() }
            check(child.waitFor() == 0) { error.ifBlank { "Local publish failed" } }
            return output
        } finally { child.destroy() }
    }
    private fun copy(source: Ref, target: Ref, move: Boolean, exclusions: List<String>, requestedName: String? = null): Map<String, Any?> {
        check(!move || source.path.isNotEmpty()) { "A storage root cannot be moved" }
        val excluded = exclusions.map { clean(it).also { value -> check(value.isNotEmpty()) { "Cannot exclude the selected root" } } }
        check(excluded.size <= 256) { "Too many exclusions" }
        if (source.kind == target.kind) check(source.path.isNotEmpty() && target.path != source.path && !target.path.startsWith(source.path + "/")) { "Choose a target outside the source folder" }
        val nodes = mutableListOf<Node>()
        var bytes = 0L
        fun scan(current: Ref, relative: String, depth: Int) {
            if (excluded.any { relative == it || relative.startsWith("$it/") }) return
            check(depth < 128 && nodes.size < 20000) { "Folder exceeds transfer limits" }
            val entry = stat(current); nodes.add(Node(relative, current, entry))
            if (entry["kind"] == "directory") for (child in list(current)) scan(Ref(current.kind, child["path"] as String), join(relative, child["name"] as String), depth + 1)
            else { bytes += (entry["size"] as Number).toLong(); check(bytes <= (100L shl 30)) { "Transfer exceeds size limit" } }
        }
        scan(source, "", 0)
        val name = requestedName ?: nodes.first().entry["name"] as String
        clean(name)
        check(list(target).none { it["name"] == name }) { "Destination already exists; overwrite denied" }
        val directory = nodes.first().entry["kind"] == "directory"
        val stageName = ".devicebridge-local-${UUID.randomUUID()}"
        var stageFile: File? = null
        var stageDocument: Uri? = null
        var published = false
        var documentRenameSupported = true
        val documents = mutableMapOf<String, Uri>()
        val hashes = mutableMapOf<String, String>()
        try {
            if (target.kind == "internal") {
                val parent = internal(target); stageFile = File(parent, stageName)
                check(stageFile.mkdir()) { "Cannot create local staging directory" }
            } else {
                stageDocument = DC.createDocument(resolver, document(target), if (directory) DC.Document.MIME_TYPE_DIR else "application/octet-stream", stageName) ?: error("Cannot create destination staging document")
                resolver.query(stageDocument!!, arrayOf(DC.Document.COLUMN_FLAGS), null, null, null)?.use { cursor ->
                    documentRenameSupported = cursor.moveToFirst() && cursor.getInt(0) and DC.Document.FLAG_SUPPORTS_RENAME != 0
                }
                if (!documentRenameSupported) {
                    check(DC.deleteDocument(resolver, stageDocument!!)) { "Cannot replace empty staging document" }
                    stageDocument = DC.createDocument(resolver, document(target), if (directory) DC.Document.MIME_TYPE_DIR else "application/octet-stream", name) ?: error("Cannot create destination")
                    resolver.query(stageDocument!!, arrayOf(DC.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor -> check(cursor.moveToFirst() && cursor.getString(0) == name) { "Destination already exists; overwrite denied" } }
                }
                documents[""] = stageDocument
            }
            for (node in nodes) {
                val isDirectory = node.entry["kind"] == "directory"
                var file: File? = null
                var doc: Uri? = null
                if (target.kind == "internal") {
                    file = File(stageFile, if (node.relative.isEmpty()) "data" else "data/${node.relative}")
                    if (isDirectory) check(file.mkdir() || file.isDirectory) { "Cannot create destination directory" }
                } else {
                    doc = if (node.relative.isEmpty()) stageDocument else {
                        val parent = documents[node.relative.substringBeforeLast('/', "")] ?: error("Destination parent missing")
                        DC.createDocument(resolver, parent, if (isDirectory) DC.Document.MIME_TYPE_DIR else "application/octet-stream", node.relative.substringAfterLast('/')) ?: error("Cannot create destination document")
                    }
                    documents[node.relative] = doc!!
                }
                if (isDirectory) continue
                var copied = 0L
                if (file != null) FileOutputStream(file).use { output -> copied = read(node.ref).use { it.copyTo(output, 256 * 1024) }; output.fd.sync() }
                else resolver.openOutputStream(doc!!, "w")!!.use { output -> copied = read(node.ref).use { it.copyTo(output, 256 * 1024) } }
                check(copied == (node.entry["size"] as Number).toLong()) { "Source changed during copy" }
                val expected = checksum(read(node.ref))
                val actual = checksum(if (file != null) file.inputStream() else resolver.openInputStream(doc!!) ?: error("Cannot reread completed destination"))
                check(expected == actual) { "XXH64 mismatch; source preserved" }
                hashes[node.relative] = expected
            }
            if (target.kind == "internal") runCore(listOf("publish-local", File(stageFile, "data").path, File(internal(target), name).path))
            else if (documentRenameSupported) {
                check(list(target).none { it["name"] == name }) { "Destination appeared during copy; overwrite denied" }
                stageDocument = DC.renameDocument(resolver, stageDocument!!, name) ?: error("Provider cannot publish the verified copy")
                resolver.query(stageDocument!!, arrayOf(DC.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor -> check(cursor.moveToFirst() && cursor.getString(0) == name) { "Provider changed the destination name; source preserved" } }
            }
            published = true
            if (move) {
                for (node in nodes.filter { it.entry["kind"] == "file" }) check(checksum(read(node.ref)) == hashes[node.relative]) { "Source changed; verified target kept and source removal stopped" }
                for (node in nodes.asReversed()) {
                    if (node.entry["kind"] != "directory" || list(node.ref).isEmpty()) delete(node.ref)
                }
            }
            return mapOf("name" to name, "bytes" to bytes, "files" to hashes.size, "checksum" to "xxh64", "moved" to move, "excluded" to excluded, "source_remaining" to if (move) try { stat(source); true } catch (_: Exception) { false } else true)
        } finally {
            stageFile?.let { if (it.exists()) it.deleteRecursively() }
            if (!published) {
                for (doc in documents.values.toList().asReversed().distinct()) try { DC.deleteDocument(resolver, doc) } catch (_: Exception) {}
                stageDocument?.let { try { DC.deleteDocument(resolver, it) } catch (_: Exception) {} }
            }
        }
    }
    fun execute(operation: String, args: Map<*, *>): Any? = when (operation) {
        "roots" -> roots()
        "list" -> mapOf("entries" to list(ref(args)))
        "stat" -> stat(ref(args))
        "mkdir" -> {
            val parent = ref(args); val name = clean(args["name"] as? String ?: "")
            check(name.isNotEmpty() && !name.contains('/')) { "Invalid folder name" }
            check(list(parent).none { it["name"] == name }) { "Folder already exists" }
            if (parent.kind == "internal") check(File(internal(parent), name).mkdir()) { "Cannot create folder" }
            else check(DC.createDocument(resolver, document(parent), DC.Document.MIME_TYPE_DIR, name) != null) { "Cannot create folder" }
            true
        }
        "transfer" -> copy(ref(args["source"] as Map<*, *>), ref(args["target"] as Map<*, *>), args["move"] == true, (args["excludes"] as? List<*>)?.map { it as String } ?: emptyList())
        "import" -> {
            val source = File(args["source_path"] as String).canonicalFile
            val root = File(activity.filesDir, "devicebridge/downloads").canonicalFile
            check(source.path.startsWith(root.path + File.separator)) { "Only verified private downloads may be imported" }
            copy(Ref("downloads", source.relativeTo(root).path), ref(args["target"] as Map<*, *>), false, emptyList(), args["name"] as? String)
        }
        "preview" -> {
            val ref = ref(args); val entry = stat(ref); check(entry["kind"] == "file") { "Select a file" }
            val data = read(ref).use { input ->
                val buffer = ByteArray(65537); var count = 0
                while (count < buffer.size) { val n = input.read(buffer, count, buffer.size-count); if (n < 0) break; count += n }
                buffer.copyOf(count)
            }
            mapOf("text" to if (data.any { it == 0.toByte() }) "Binary file. Use Open with to view it." else String(data.take(65536).toByteArray(), Charsets.UTF_8), "truncated" to (data.size > 65536), "name" to entry["name"])
        }
        "open" -> {
            val ref = ref(args); val entry = stat(ref)
            val uri = if (ref.kind == "internal" || ref.kind == "downloads") FileProvider.getUriForFile(activity, "${activity.packageName}.files", internal(ref)) else document(ref)
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension((entry["name"] as String).substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"
            val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.clipData = ClipData.newRawUri("DeviceBridge file", uri)
            activity.runOnUiThread { activity.startActivity(Intent.createChooser(intent, "Open with")) }
            true
        }
        else -> error("Unknown local file operation")
    }
}
