package dev.devicebridge.devicebridge

import android.app.Activity
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.net.Inet4Address
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var saveResult: MethodChannel.Result? = null
    private var saveSource: File? = null
    private lateinit var lan: LanCoordinator
    private lateinit var tailnet: TailnetCoordinator
    private var networkSink: EventChannel.EventSink? = null
    private var networkStatus: Map<String, Any?>? = null
    private var transferSink: EventChannel.EventSink? = null

    override fun onResume() { super.onResume(); if (::lan.isInitialized) lan.visible(true); if (::tailnet.isInitialized) tailnet.visible(true) }
    override fun onStop() { if (::lan.isInitialized) lan.visible(false); if (::tailnet.isInitialized) tailnet.visible(false); super.onStop() }

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
                "networks" -> {
                    result.success(lan.networks())
                }
                "activateLan" -> { lan.activate(call.argument<Map<String, Any?>>("network")); result.success(null) }
                "approveLan" -> {
                    try { lan.approve(call.argument<Map<String, Any?>>("network") ?: emptyMap()); result.success(null) }
                    catch (e: Exception) { result.error("network_changed", e.message, null) }
                }
                "tailnetEnable" -> { tailnet.enable(call.argument<Boolean>("enabled") == true); result.success(null) }
                "openLogin" -> {
                    val value = call.argument<String>("url") ?: ""
                    val uri = android.net.Uri.parse(value)
                    if (uri.scheme == "https" && uri.host == "login.tailscale.com") { startActivity(Intent(Intent.ACTION_VIEW, uri)); result.success(null) }
                    else result.error("invalid_login", "Only the official Tailscale login page may be opened", null)
                }
                "connectionSetup" -> {
                    val kind = call.argument<String>("kind")
                    if (kind == "wifi_direct" && !packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_WIFI_DIRECT)) {
                        result.error("unavailable", "This device does not report Wi-Fi Direct support", null)
                    } else {
                        val action = if (kind == "hotspot") "android.settings.TETHER_SETTINGS" else "android.settings.WIFI_DIRECT_SETTINGS"
                        var intent = Intent(action)
                        if (intent.resolveActivity(packageManager) == null) intent = Intent(android.provider.Settings.ACTION_WIFI_SETTINGS)
                        try { startActivity(intent); result.success(null) } catch(e: Exception) { result.error("unavailable", e.message, null) }
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
                    fun copy(dir: File, target: android.net.Uri) {
                        for (child in dir.listFiles() ?: error("Cannot enumerate verified download")) {
                            check(child.canonicalPath.startsWith(source.canonicalPath + File.separator)) { "Unsafe download entry" }
                            val doc = DocumentsContract.createDocument(contentResolver, target,
                                if (child.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream", child.name) ?: error("Cannot create document")
                            if (child.isDirectory) copy(child, doc) else contentResolver.openOutputStream(doc, "w")!!.use { output -> child.inputStream().use { it.copyTo(output) } }
                        }
                    }
                    copy(source, dest)
                }
                runOnUiThread { reply.success(uri.toString()) }
            } catch (e: Exception) { runOnUiThread { reply.error("save_failed", "Copy incomplete; verified private download preserved. ${e.message}", null) } }
        }
    }
}
