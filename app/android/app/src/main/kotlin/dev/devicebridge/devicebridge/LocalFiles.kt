package dev.devicebridge.devicebridge

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract as DC
import android.util.AtomicFile
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.io.FileOutputStream
import java.nio.file.Files
import java.util.UUID

internal const val TERMUX_DOCUMENTS_AUTHORITY = "com.termux.documents"

internal fun requireSafFolder(uri: Uri): Uri {
    check(uri.authority != TERMUX_DOCUMENTS_AUTHORITY) { "Open the paired Termux device in Files to access Termux Home" }
    return uri
}

/** Native phone directories and Termux Home with Recycle Bin support. */
class LocalFiles(private val activity: Activity, private val checksum: (InputStream) -> String) {
    companion object {
        private val trashLock = Any()
        private const val INTERNAL_TRASH_DIR = ".devicebridge-recycle-bin"
    }
    private val resolver get() = activity.contentResolver
    private val prefs = activity.getSharedPreferences("devicebridge-targets", Activity.MODE_PRIVATE)
    data class Ref(val kind: String, val path: String)
    data class Node(val relative: String, val ref: Ref, val entry: Map<String, Any?>)
    private fun isPosix(kind: String) = kind == "internal" || kind == "termux_home" || kind == "downloads"
    private fun termuxHomeDir(): File = File(activity.filesDir, "terminal/files/home").apply { mkdirs() }.canonicalFile
    private fun recycleMetaFile(): File = File(activity.filesDir, "devicebridge/recycle-bin/metadata.json").apply { parentFile?.mkdirs() }
    private fun clean(value: String): String {
        if (value == "." || value.isEmpty()) return ""
        check(!value.startsWith('/') && !value.contains('\\') && !value.contains('\u0000') && value.split('/').none { it.isEmpty() || it == "." || it == ".." }) { "Unsafe relative path" }
        return value
    }
    private fun ref(map: Map<*, *>): Ref {
        val kind = map["kind"] as? String ?: error("Storage kind required")
        check(kind in setOf("internal", "termux_home", "recycle_bin", "saf", "downloads")) { "Unknown storage provider" }
        return Ref(kind, clean(map["path"] as? String ?: ""))
    }
    private fun join(a: String, b: String) = if (a.isEmpty()) b else "$a/$b"
    private fun internal(ref: Ref): File {
        if (ref.kind == "internal") check(Environment.isExternalStorageManager()) { "Grant phone storage access first" }
        val root = when (ref.kind) {
            "termux_home" -> termuxHomeDir()
            "downloads" -> File(activity.filesDir, "devicebridge/downloads").apply { mkdirs() }.canonicalFile
            "internal" -> Environment.getExternalStorageDirectory().canonicalFile
            else -> error("Not a native directory")
        }
        val candidate = if (ref.path.isEmpty()) root else File(root, ref.path)
        check(candidate.canonicalPath == candidate.absolutePath && (candidate == root || candidate.path.startsWith(root.path + File.separator))) { "Symlinks or storage escape rejected" }
        return candidate
    }
    private val documentCache = mutableMapOf<Ref, Uri>()
    private fun tree(): Uri {
        val raw = prefs.getString("saf_uri", null) ?: error("Choose an SAF folder first")
        val uri = requireSafFolder(Uri.parse(raw))
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
    private fun document(ref: Ref): Uri {
        val root = tree()
        documentCache[ref]?.let {
            if (it.authority == root.authority && DC.getTreeDocumentId(it) == DC.getTreeDocumentId(root)) return it
        }
        var current = DC.buildDocumentUriUsingTree(root, DC.getTreeDocumentId(root))
        if (ref.path.isNotEmpty()) for (part in ref.path.split('/')) {
            current = Uri.parse(children(current).singleOrNull { it["name"] == part }?.get("uri") as? String ?: error("Document no longer exists: $part"))
        }
        documentCache[ref] = current
        return current
    }

    fun roots(): List<Map<String, Any?>> = listOf(
        mapOf("id" to "internal", "name" to "Internal storage", "available" to Environment.isExternalStorageManager(), "native_path" to Environment.getExternalStorageDirectory().canonicalPath),
        mapOf("id" to "termux_home", "name" to "Termux Home", "available" to true, "native_path" to termuxHomeDir().canonicalPath),
        mapOf("id" to "recycle_bin", "name" to "Recycle Bin", "available" to true),
    )
    fun list(ref: Ref): List<Map<String, Any?>> {
        if (ref.kind == "recycle_bin") return listTrash()
        if (isPosix(ref.kind)) return (internal(ref).listFiles() ?: error("Folder cannot be read")).mapNotNull { file ->
            if (ref.kind == "internal" && ref.path.isEmpty() && file.name == INTERNAL_TRASH_DIR) return@mapNotNull null
            try { val child = Ref(ref.kind, join(ref.path, file.name)); val checked = internal(child); if (!checked.isFile && !checked.isDirectory) null else mapOf("name" to checked.name, "path" to child.path, "kind" to if (checked.isDirectory) "directory" else "file", "size" to checked.length(), "modified" to checked.lastModified()) } catch (_: Exception) { null }
        }.sortedWith(compareBy<Map<String, Any?>> { if (it["kind"] == "directory") 0 else 1 }.thenBy { (it["name"] as String).lowercase() })
        return children(document(ref)).map {
            val path = join(ref.path, it["name"] as String)
            documentCache[Ref(ref.kind, path)] = Uri.parse(it["uri"] as String)
            it + ("path" to path) - "uri"
        }
    }
    fun stat(ref: Ref): Map<String, Any?> {
        if (isPosix(ref.kind)) { val f = internal(ref); check(f.exists()) { "Source no longer exists" }; return mapOf("name" to f.name, "kind" to if (f.isDirectory) "directory" else "file", "size" to f.length()) }
        val uri = document(ref)
        resolver.query(uri, arrayOf(DC.Document.COLUMN_DISPLAY_NAME, DC.Document.COLUMN_MIME_TYPE, DC.Document.COLUMN_SIZE), null, null, null)?.use { cursor ->
            check(cursor.moveToFirst()) { "Source no longer exists" }
            return mapOf("name" to cursor.getString(0), "kind" to if (cursor.getString(1) == DC.Document.MIME_TYPE_DIR) "directory" else "file", "size" to cursor.getLong(2))
        }
        error("Cannot inspect source")
    }
    fun read(ref: Ref): InputStream = if (isPosix(ref.kind)) internal(ref).inputStream() else resolver.openInputStream(document(ref)) ?: error("Cannot open document")
    private fun delete(ref: Ref) {
        check(ref.path.isNotEmpty()) { "A storage root cannot be moved" }
        if (isPosix(ref.kind)) check(internal(ref).delete()) { "Cannot remove verified source" }
        else check(DC.deleteDocument(resolver, document(ref))) { "Cannot remove verified source document" }
    }
    private fun runCore(arguments: List<String>): String {
        val binary = GoBinaryManager.resolve(activity, "cli")
        val child = ProcessBuilder(listOf(binary.path, "--state", File(activity.filesDir, "devicebridge").path) + arguments).start()
        try {
            child.outputStream.close()
            val output = child.inputStream.bufferedReader().use { it.readText() }
            val error = child.errorStream.bufferedReader().use { it.readText() }
            check(child.waitFor() == 0) { error.ifBlank { "Local publish failed" } }
            return output
        } finally { child.destroy() }
    }
    private fun scanTree(source: Ref, excluded: List<String>): Pair<List<Node>, Long> {
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
        return nodes to bytes
    }

    private fun uploadStage(id: String): Ref {
        check(id.matches(Regex("[.]devicebridge-upload-[a-f0-9-]{36}"))) { "Invalid upload staging folder" }
        return Ref("downloads", id)
    }

    private fun stageUpload(source: Ref, exclusions: List<String>): Map<String, String> {
        check(source.path.isNotEmpty()) { "Select a file or folder" }
        if (source.kind != "saf") {
            val file = internal(source)
            check(file.isFile || file.isDirectory) { "Source is unavailable" }
            return mapOf("path" to file.path)
        }
        val stage = uploadStage(".devicebridge-upload-${UUID.randomUUID()}")
        val folder = internal(stage)
        check(folder.mkdir()) { "Cannot create private upload staging" }
        try {
            val copy = copy(source, stage, false, exclusions)
            val name = copy["name"] as String
            return mapOf("path" to File(folder, name).path, "stage" to stage.path)
        } catch (e: Exception) {
            folder.deleteRecursively()
            throw e
        }
    }

    private fun finishStagedUpload(source: Ref, stage: Ref, move: Boolean, exclusions: List<String>): Boolean {
        val folder = internal(stage)
        try {
            if (!move) return true
            check(source.kind == "saf" && source.path.isNotEmpty()) { "Invalid staged move source" }
            val staged = folder.listFiles()?.singleOrNull() ?: error("Verified upload snapshot is missing")
            val (snapshot, _) = scanTree(Ref("downloads", join(stage.path, staged.name)), emptyList())
            val (current, _) = scanTree(source, exclusions.map(::clean))
            val byPath = snapshot.associateBy { it.relative }
            check(current.size == byPath.size && current.all { byPath[it.relative]?.entry?.get("kind") == it.entry["kind"] }) {
                "Copy verified. The source folder changed and was preserved."
            }
            val hashes = current.filter { it.entry["kind"] == "file" }.associate { node ->
                val expected = checksum(read(byPath.getValue(node.relative).ref))
                check(expected == checksum(read(node.ref))) { "Copy verified. A source file changed and was preserved." }
                node.relative to expected
            }
            for (node in current.asReversed()) {
                if (node.entry["kind"] == "directory") {
                    if (list(node.ref).isEmpty()) delete(node.ref)
                } else {
                    check(checksum(read(node.ref)) == hashes.getValue(node.relative)) { "Copy verified. Source cleanup stopped at a changed file." }
                    delete(node.ref)
                }
            }
            return runCatching { stat(source) }.isSuccess
        } finally {
            folder.deleteRecursively()
        }
    }

    private fun copy(source: Ref, target: Ref, move: Boolean, exclusions: List<String>, requestedName: String? = null): Map<String, Any?> {
        check(!move || source.path.isNotEmpty()) { "A storage root cannot be moved" }
        val excluded = exclusions.map { clean(it).also { value -> check(value.isNotEmpty()) { "Cannot exclude the selected root" } } }
        check(excluded.size <= 256) { "Too many exclusions" }
        if (source.kind == target.kind) check(source.path.isNotEmpty() && target.path != source.path && !target.path.startsWith(source.path + "/")) { "Choose a target outside the source folder" }
        val (nodes, bytes) = scanTree(source, excluded)
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
            if (isPosix(target.kind)) {
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
                if (isPosix(target.kind)) {
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
            if (isPosix(target.kind)) runCore(listOf("publish-local", File(stageFile, "data").path, File(internal(target), name).path))
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
    private fun deleteTreeSafely(target: File) {
        val path = target.toPath()
        if (Files.isSymbolicLink(path)) {
            Files.deleteIfExists(path)
            return
        }
        if (target.isDirectory) {
            target.listFiles()?.forEach { deleteTreeSafely(it) }
        }
        check(target.delete() || !target.exists()) { "Cannot delete ${target.name}" }
    }

    private fun readTrashEntries(): MutableList<JSONObject> {
        val file = recycleMetaFile()
        if (!file.exists()) return mutableListOf()
        val raw = AtomicFile(file).openRead().bufferedReader().use { it.readText().trim() }
        if (raw.isEmpty()) return mutableListOf()
        val arr = JSONArray(raw)
        return MutableList(arr.length()) { arr.getJSONObject(it) }
    }

    private fun writeTrashEntries(entries: List<JSONObject>) {
        val file = recycleMetaFile()
        val arr = JSONArray()
        entries.forEach { arr.put(it) }
        val atomic = AtomicFile(file)
        val payload = arr.toString().toByteArray(Charsets.UTF_8)
        val output = atomic.startWrite()
        try {
            output.write(payload)
            atomic.finishWrite(output)
        } catch (error: Exception) {
            atomic.failWrite(output)
            throw error
        }
        check(atomic.readFully().contentEquals(payload)) { "Cannot update Recycle Bin index" }
    }

    private fun listTrash(): List<Map<String, Any?>> = synchronized(trashLock) {
        val hasAllFiles = Environment.isExternalStorageManager()
        readTrashEntries().mapNotNull { obj ->
            val origKind = obj.optString("original_kind")
            if (origKind == "internal" && !hasAllFiles) return@mapNotNull null
            val storageFile = File(obj.optString("storage_path"))
            if (!storageFile.exists() && !Files.isSymbolicLink(storageFile.toPath())) return@mapNotNull null
            val origPath = obj.optString("original_path")
            val kindLabel = if (origKind == "termux_home") "Termux Home" else "Internal storage"
            mapOf(
                "name" to obj.optString("name"),
                "path" to obj.optString("id"),
                "kind" to obj.optString("kind", "file"),
                "size" to obj.optLong("size", 0L),
                "modified" to obj.optLong("deleted_at", 0L),
                "original_kind" to origKind,
                "original_path" to origPath,
                "original_label" to "$kindLabel/$origPath",
            )
        }.sortedByDescending { (it["modified"] as? Long) ?: 0L }
    }

    private fun moveToTrash(source: Ref): Map<String, Any?> {
        check(source.kind == "internal" || source.kind == "termux_home") { "Only Internal storage or Termux Home items can be moved to Recycle Bin" }
        check(source.path.isNotEmpty()) { "A storage root cannot be moved to Recycle Bin" }
        val file = internal(source)
        check(file.exists()) { "Item no longer exists" }
        val id = UUID.randomUUID().toString()
        val entryKind = if (file.isDirectory) "directory" else "file"
        val size = if (file.isDirectory) 0L else file.length()
        val wrapper = if (source.kind == "internal") {
            File(Environment.getExternalStorageDirectory().canonicalFile, "$INTERNAL_TRASH_DIR/$id")
        } else {
            File(activity.filesDir.canonicalFile, "devicebridge/recycle-bin/items/$id")
        }
        synchronized(trashLock) {
            val entries = readTrashEntries()
            check(wrapper.mkdirs()) { "Cannot prepare Recycle Bin storage" }
            val dest = File(wrapper, file.name)
            entries.add(
                JSONObject()
                    .put("id", id)
                    .put("name", dest.name)
                    .put("kind", entryKind)
                    .put("size", size)
                    .put("deleted_at", System.currentTimeMillis())
                    .put("original_kind", source.kind)
                    .put("original_path", source.path)
                    .put("storage_path", dest.absolutePath)
            )
            try {
                // A process death may leave an index record without a payload,
                // which the Recycle Bin already hides. The inverse loses track
                // of a user's file.
                writeTrashEntries(entries)
                runCore(listOf("move-local-no-replace", file.path, dest.path))
            } catch (error: Exception) {
                if (!dest.exists() && !Files.isSymbolicLink(dest.toPath())) {
                    entries.removeAt(entries.lastIndex)
                    runCatching { writeTrashEntries(entries) }
                    wrapper.delete()
                }
                throw error
            }
            return mapOf("id" to id, "name" to dest.name)
        }
    }

    private fun restoreFromTrash(id: String): Map<String, Any?> {
        check(id.isNotEmpty()) { "Recycle Bin item ID is required" }
        synchronized(trashLock) {
            val entries = readTrashEntries()
            val idx = entries.indexOfFirst { it.optString("id") == id }
            check(idx >= 0) { "Recycle Bin item no longer exists" }
            val obj = entries[idx]
            val origKind = obj.optString("original_kind")
            val origPath = clean(obj.optString("original_path"))
            val storageFile = File(obj.optString("storage_path"))
            check(storageFile.exists() || Files.isSymbolicLink(storageFile.toPath())) { "Trashed item payload is missing" }
            val dest = internal(Ref(origKind, origPath))
            check(!dest.exists() && !Files.isSymbolicLink(dest.toPath())) { "Destination already exists; restore denied" }
            dest.parentFile?.mkdirs()
            runCore(listOf("move-local-no-replace", storageFile.path, dest.path))
            storageFile.parentFile?.let { if (it.listFiles()?.isEmpty() == true) it.delete() }
            entries.removeAt(idx)
            writeTrashEntries(entries)
            return mapOf("name" to dest.name, "kind" to origKind, "path" to origPath)
        }
    }

    private fun deletePermanent(target: Ref): Boolean {
        if (target.kind == "recycle_bin") {
            check(target.path.isNotEmpty()) { "Recycle Bin item ID is required" }
            synchronized(trashLock) {
                val entries = readTrashEntries()
                val idx = entries.indexOfFirst { it.optString("id") == target.path }
                check(idx >= 0) { "Recycle Bin item no longer exists" }
                val storageFile = File(entries[idx].optString("storage_path"))
                if (storageFile.exists() || Files.isSymbolicLink(storageFile.toPath())) {
                    deleteTreeSafely(storageFile)
                }
                storageFile.parentFile?.let { if (it.listFiles()?.isEmpty() == true) it.delete() }
                entries.removeAt(idx)
                writeTrashEntries(entries)
            }
            return true
        }
        check(isPosix(target.kind) && target.path.isNotEmpty()) { "A storage root cannot be deleted" }
        val file = internal(target)
        check(file.exists() || Files.isSymbolicLink(file.toPath())) { "Item no longer exists" }
        deleteTreeSafely(file)
        return true
    }

    private fun emptyTrash(): Int {
        synchronized(trashLock) {
            val entries = readTrashEntries()
            var removed = 0
            for (obj in entries) {
                val storageFile = File(obj.optString("storage_path"))
                if (storageFile.exists() || Files.isSymbolicLink(storageFile.toPath())) {
                    deleteTreeSafely(storageFile)
                }
                storageFile.parentFile?.let { if (it.listFiles()?.isEmpty() == true) it.delete() }
                removed++
            }
            writeTrashEntries(emptyList())
            return removed
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
            if (isPosix(parent.kind)) check(File(internal(parent), name).mkdir()) { "Cannot create folder" }
            else check(DC.createDocument(resolver, document(parent), DC.Document.MIME_TYPE_DIR, name) != null) { "Cannot create folder" }
            true
        }
        "trash" -> moveToTrash(ref(args))
        "restore" -> restoreFromTrash((args["id"] as? String) ?: (args["path"] as? String) ?: "")
        "delete" -> deletePermanent(ref(args))
        "empty-trash" -> mapOf("removed" to emptyTrash())
        "transfer" -> copy(ref(args["source"] as Map<*, *>), ref(args["target"] as Map<*, *>), args["move"] == true, (args["excludes"] as? List<*>)?.map { it as String } ?: emptyList())
        "upload-source" -> stageUpload(ref(args), (args["excludes"] as? List<*>)?.map { it as String } ?: emptyList())
        "finish-upload" -> finishStagedUpload(
            ref(args), uploadStage(args["stage"] as String), args["move"] == true,
            (args["excludes"] as? List<*>)?.map { it as String } ?: emptyList(),
        )
        "import" -> {
            val source = File(args["source_path"] as String).canonicalFile
            val root = File(activity.filesDir, "devicebridge/downloads").canonicalFile
            check(source.path.startsWith(root.path + File.separator)) { "Only verified private downloads may be imported" }
            copy(Ref("downloads", source.relativeTo(root).path), ref(args["target"] as Map<*, *>), args["evict_staging"] == true, emptyList(), args["name"] as? String)
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
        "sync-location" -> {
            val source = ref(args)
            check(source.kind == "internal" || source.kind == "termux_home") { "Folder sync needs a native folder. Choose Internal storage, Termux Home or a paired device." }
            val folder = internal(source)
            check(folder.isDirectory && folder.canRead() && folder.canWrite()) { "Choose a readable and writable folder for sync" }
            mapOf("path" to folder.path)
        }
        "open" -> {
            val ref = ref(args); val entry = stat(ref)
            val uri = if (isPosix(ref.kind)) FileProvider.getUriForFile(activity, "${activity.packageName}.files", internal(ref)) else document(ref)
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension((entry["name"] as String).substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"
            val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.clipData = ClipData.newRawUri("DeviceBridge file", uri)
            activity.runOnUiThread { activity.startActivity(Intent.createChooser(intent, "Open with")) }
            true
        }
        else -> error("Unknown local file operation")
    }
}
