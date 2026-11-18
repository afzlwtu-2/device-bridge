package dev.devicebridge.devicebridge

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var saveResult: MethodChannel.Result? = null
    private var saveSource: File? = null
    private var treeResult: MethodChannel.Result? = null
    private var treeKind: String = "saf"
    private lateinit var lan: LanCoordinator
    private lateinit var tailnet: TailnetCoordinator
    private var networkSink: EventChannel.EventSink? = null
    private var networkStatus: Map<String, Any?>? = null
    private var transferSink: EventChannel.EventSink? = null
    private val targetPrefs by lazy { getSharedPreferences("devicebridge-targets", Context.MODE_PRIVATE) }

    override fun onResume() { super.onResume(); if (::lan.isInitialized) lan.visible(true); if (::tailnet.isInitialized) tailnet.visible(true) }
    override fun onStop() { if (::lan.isInitialized) lan.visible(false); if (::tailnet.isInitialized) tailnet.visible(false); super.onStop() }

    private fun isTermuxInstalled(): Boolean = try {
        packageManager.getPackageInfo("com.termux", 0); true
    } catch (_: PackageManager.NameNotFoundException) { false }

    private fun copyFileOrDirToDocument(source: File, parentDocUri: Uri) {
        if (!source.isDirectory) {
            val doc = DocumentsContract.createDocument(contentResolver, parentDocUri, "application/octet-stream", source.name)
                ?: error("Cannot create destination file")
            contentResolver.openOutputStream(doc, "w")!!.use { output -> source.inputStream().use { it.copyTo(output) } }
            return
        }
        val destName = source.name
        val dest = DocumentsContract.createDocument(contentResolver, parentDocUri, DocumentsContract.Document.MIME_TYPE_DIR, destName)
            ?: DocumentsContract.createDocument(contentResolver, parentDocUri, DocumentsContract.Document.MIME_TYPE_DIR, destName + "-" + UUID.randomUUID().toString().take(8))
            ?: error("Cannot create destination folder")
        fun copy(dir: File, target: Uri) {
            for (child in dir.listFiles() ?: error("Cannot enumerate verified download")) {
                check(child.canonicalPath.startsWith(source.canonicalPath + File.separator)) { "Unsafe download entry" }
                val doc = DocumentsContract.createDocument(
                    contentResolver,
                    target,
                    if (child.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream",
                    child.name
                ) ?: error("Cannot create document")
                if (child.isDirectory) copy(child, doc) else contentResolver.openOutputStream(doc, "w")!!.use { output -> child.inputStream().use { it.copyTo(output) } }
            }
        }
        copy(source, dest)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        tailnet = TailnetCoordinator(applicationContext)
        lan = LanCoordinator(applicationContext) { value ->
            networkStatus = value; networkSink?.success(value)
            @Suppress("UNCHECKED_CAST")
            val network = value["network"] as? Map<String, Any?>
            tailnet.network(network, value["endpoint"] as? String ?: "")
        }
        EventChannel(engine.dartExecutor.binaryMessenger, "dev.devicebridge/network").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { networkSink = events; networkStatus?.let { events.success(it) } }
            override fun onCancel(arguments: Any?) { networkSink = null }
        })
        EventChannel(engine.dartExecutor.binaryMessenger, "dev.devicebridge/transfer").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { transferSink = events }
            override fun onCancel(arguments: Any?) { transferSink = null }
        })
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.devicebridge/core").setMethodCallHandler { call, result ->
            when (call.method) {
                "configuration" -> result.success(mapOf(
                    "state" to File(filesDir, "devicebridge").path,
                    "binary" to File(applicationInfo.nativeLibraryDir, "libbridge_cli.so").path
                ))
                "networks" -> result.success(lan.networks())
                "activateLan" -> { lan.activate(call.argument<Map<String, Any?>>("network")); result.success(null) }
                "approveLan" -> {
                    try { lan.approve(call.argument<Map<String, Any?>>("network") ?: emptyMap()); result.success(null) }
                    catch (e: Exception) { result.error("network_changed", e.message, null) }
                }
                "tailnetEnable" -> { tailnet.enable(call.argument<Boolean>("enabled") == true); result.success(null) }
                "openLogin" -> {
                    val value = call.argument<String>("url") ?: ""
                    val uri = Uri.parse(value)
                    if (uri.scheme == "https" && uri.host == "login.tailscale.com") {
                        tailnet.awaitingLogin()
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(null)
                    } else result.error("invalid_login", "Only the official Tailscale login page may be opened", null)
                }
                "platformCapabilities" -> {
                    val adbEnabled = try { Settings.Global.getInt(contentResolver, Settings.Global.ADB_ENABLED, 0) == 1 } catch (_: Exception) { false }
                    result.success(mapOf(
                        "wifi_direct" to packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT),
                        "adb_enabled" to adbEnabled,
                        "termux_installed" to isTermuxInstalled(),
                        "saf_tree_uri" to targetPrefs.getString("saf_uri", null),
                        "saf_tree_name" to targetPrefs.getString("saf_name", null),
                        "termux_tree_uri" to targetPrefs.getString("termux_uri", null),
                        "termux_tree_name" to targetPrefs.getString("termux_name", null)
                    ))
                }
                "connectionSetup" -> {
                    val kind = call.argument<String>("kind")
                    if (kind == "wifi_direct" && !packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)) {
                        result.error("unavailable", "This device does not report Wi-Fi Direct support", null)
                    } else {
                        val action = when (kind) {
                            "hotspot" -> "android.settings.TETHER_SETTINGS"
                            "wifi_direct" -> "android.settings.WIFI_DIRECT_SETTINGS"
                            "adb" -> Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS
                            else -> Settings.ACTION_WIFI_SETTINGS
                        }
                        var intent = Intent(action)
                        if (intent.resolveActivity(packageManager) == null) intent = Intent(Settings.ACTION_WIFI_SETTINGS)
                        try { startActivity(intent); result.success(null) } catch(e: Exception) { result.error("unavailable", e.message, null) }
                    }
                }
                "pickTargetTree" -> {
                    if (treeResult != null) {
                        result.error("busy", "A folder picker is already open", null)
                    } else {
                        val termux = call.argument<Boolean>("termux") == true
                        treeKind = if (termux) "termux" else "saf"
                        treeResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                            if (termux && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse("content://com.termux.documents/tree/%2Fdata%2Fdata%2Fcom.termux%2Ffiles%2Fhome"))
                            }
                        }
                        startActivityForResult(intent, 402)
                    }
                }
                "listTargetTree" -> {
                    val treeUriStr = call.argument<String>("uri")
                    val docId = call.argument<String>("document_id")
                    if (treeUriStr.isNullOrBlank()) {
                        result.error("invalid_uri", "No SAF target tree selected", null)
                    } else {
                        worker.execute {
                            try {
                                val treeUri = Uri.parse(treeUriStr)
                                val parentId = if (docId.isNullOrBlank()) DocumentsContract.getTreeDocumentId(treeUri) else docId
                                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
                                val entries = mutableListOf<Map<String, Any?>>()
                                val cols = arrayOf(
                                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                                    DocumentsContract.Document.COLUMN_SIZE,
                                    DocumentsContract.Document.COLUMN_LAST_MODIFIED
                                )
                                contentResolver.query(childrenUri, cols, null, null, null)?.use { c ->
                                    val iId = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                                    val iName = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                                    val iMime = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                                    val iSize = c.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                                    val iMod = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                                    while (c.moveToNext()) {
                                        val name = c.getString(iName) ?: continue
                                        val mime = c.getString(iMime) ?: ""
                                        val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR
                                        entries.add(mapOf(
                                            "name" to name,
                                            "document_id" to c.getString(iId),
                                            "kind" to if (isDir) "directory" else "file",
                                            "size" to if (iSize >= 0 && !c.isNull(iSize)) c.getLong(iSize) else 0L,
                                            "modified_ms" to if (iMod >= 0 && !c.isNull(iMod)) c.getLong(iMod) else 0L
                                        ))
                                    }
                                }
                                entries.sortWith(compareBy<Map<String, Any?>>({ it["kind"] != "directory" }, { (it["name"] as String).lowercase() }))
                                runOnUiThread { result.success(mapOf("root_document_id" to DocumentsContract.getTreeDocumentId(treeUri), "document_id" to parentId, "entries" to entries)) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("target_list_failed", e.message, null) }
                            }
                        }
                    }
                }
                "createTargetFolder" -> {
                    val treeUriStr = call.argument<String>("uri")
                    val docId = call.argument<String>("document_id")
                    val name = call.argument<String>("name")
                    if (treeUriStr.isNullOrBlank() || name.isNullOrBlank()) {
                        result.error("invalid_args", "Folder name and target URI required", null)
                    } else {
                        worker.execute {
                            try {
                                val treeUri = Uri.parse(treeUriStr)
                                val parentId = if (docId.isNullOrBlank()) DocumentsContract.getTreeDocumentId(treeUri) else docId
                                val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
                                val created = DocumentsContract.createDocument(contentResolver, parentUri, DocumentsContract.Document.MIME_TYPE_DIR, name)
                                    ?: error("Cannot create folder")
                                runOnUiThread { result.success(DocumentsContract.getDocumentId(created)) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("mkdir_failed", e.message, null) }
                            }
                        }
                    }
                }
                "exportToTargetTree" -> {
                    val sourcePath = call.argument<String>("path") ?: ""
                    val treeUriStr = call.argument<String>("uri") ?: ""
                    val docId = call.argument<String>("document_id")
                    worker.execute {
                        try {
                            val source = File(sourcePath).canonicalFile
                            val downloads = File(filesDir, "devicebridge/downloads").canonicalFile
                            check(source.path.startsWith(downloads.path + File.separator) && source.exists()) { "Only verified app downloads may be exported" }
                            val treeUri = Uri.parse(treeUriStr)
                            val parentId = if (docId.isNullOrBlank()) DocumentsContract.getTreeDocumentId(treeUri) else docId
                            val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
                            copyFileOrDirToDocument(source, parentUri)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("export_failed", "Verified private download preserved. ${e.message}", null) }
                        }
                    }
                }
                "execute" -> {
                    val args = call.argument<List<String>>("arguments") ?: emptyList()
                    val input = call.argument<String>("input") ?: ""
                    val transfer = call.argument<Boolean>("transfer") ?: false
                    if (args.size < 3 || args[0] != "--state" || args[1] != File(filesDir, "devicebridge").path) {
                        result.error("invalid_arguments", "Core state must remain inside this app", null)
                    } else {
                        if (transfer) { tailnet.transferring(true); startForegroundService(Intent(this, TransferService::class.java)) }
                        worker.execute {
                            try {
                                val output = CoreRuntime.execute(applicationContext, args, input) { progress ->
                                    runOnUiThread { transferSink?.success(progress) }
                                }
                                runOnUiThread { result.success(output) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("core_failed", e.message, null) }
                            } finally {
                                if (transfer) runOnUiThread { stopService(Intent(this, TransferService::class.java)); tailnet.transferring(false) }
                            }
                        }
                    }
                }
                "cancel" -> { CoreRuntime.cancel(); result.success(null) }
                "saveDownload" -> {
                    try {
                        check(saveResult == null) { "A document picker is already open" }
                        val source = File(call.argument<String>("path") ?: "").canonicalFile
                        val downloads = File(filesDir, "devicebridge/downloads").canonicalFile
                        check(source.path.startsWith(downloads.path + File.separator) && source.exists()) { "Only verified app downloads may be exported" }
                        saveSource = source
                        saveResult = result
                        val intent = if (source.isDirectory) Intent(Intent.ACTION_OPEN_DOCUMENT_TREE) else
                            Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, source.name)
                        startActivityForResult(intent, 401)
                    } catch (e: Exception) { saveResult = null; saveSource = null; result.error("save_failed", e.message, null) }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Activity result bridge for FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 402) {
            val reply = treeResult ?: return
            treeResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { reply.success(null); return }
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            } catch (_: Exception) { /* some providers grant non-persistable session access */ }
            val docId = try { DocumentsContract.getTreeDocumentId(uri) } catch (_: Exception) { uri.lastPathSegment ?: "folder" }
            val label = docId.substringAfter(':').ifEmpty { docId }
            targetPrefs.edit()
                .putString("${treeKind}_uri", uri.toString())
                .putString("${treeKind}_name", label)
                .apply()
            reply.success(mapOf("uri" to uri.toString(), "name" to label, "kind" to treeKind))
            return
        }
        if (requestCode != 401) return
        val reply = saveResult ?: return
        val source = saveSource
        saveResult = null
        saveSource = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || source == null) { reply.success(null); return }
        worker.execute {
            try {
                if (!source.isDirectory) {
                    contentResolver.openOutputStream(uri, "w")!!.use { output -> source.inputStream().use { it.copyTo(output) } }
                } else {
                    val parent = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
                    val name = source.name + "-" + UUID.randomUUID().toString().take(8)
                    val dest = DocumentsContract.createDocument(contentResolver, parent, DocumentsContract.Document.MIME_TYPE_DIR, name) ?: error("Cannot create destination folder")
                    copyFileOrDirToDocument(source, dest)
                }
                runOnUiThread { reply.success(uri.toString()) }
            } catch (e: Exception) { runOnUiThread { reply.error("save_failed", "Copy incomplete; verified private download preserved. ${e.message}", null) } }
        }
    }
}
