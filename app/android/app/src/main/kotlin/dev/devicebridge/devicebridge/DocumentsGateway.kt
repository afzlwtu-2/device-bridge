package dev.devicebridge.devicebridge

import android.app.Activity
import org.json.JSONObject
import org.json.JSONArray
import java.net.ServerSocket
import java.net.InetAddress
import java.net.Socket
import java.security.SecureRandom
import java.security.MessageDigest
import java.time.Instant
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Authenticated, read-only loopback adapter for the packaged Go file provider. */
class DocumentsGateway(private val activity: Activity) {
    private val token = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
    private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    private val workers = ThreadPoolExecutor(2, 4, 15, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(16))
    private val local = LocalFiles(activity) { error("Gateway never performs writes") }
    @Volatile private var closed = false
    init {
        Thread({
            while (!closed) {
                try {
                    val socket = server.accept()
                    try { workers.execute { handle(socket) } } catch (_: Exception) { socket.close() }
                } catch (_: Exception) { if (closed) break }
            }
        }, "DeviceBridge documents accept").apply { isDaemon = true }.start()
    }
    fun environment(): Map<String, String> {
        if (local.roots().none { it["id"] == "saf" && it["available"] == true }) return emptyMap()
        return mapOf("DEVICEBRIDGE_DOCUMENTS_ENDPOINT" to "127.0.0.1:${server.localPort}", "DEVICEBRIDGE_DOCUMENTS_TOKEN" to token, "DEVICEBRIDGE_DOCUMENTS_KINDS" to "saf")
    }
    private fun wireEntry(entry: Map<String, Any?>): Map<String, Any?> = entry + ("modified" to Instant.ofEpochMilli((entry["modified"] as? Number)?.toLong() ?: 0L).toString())
    private fun handle(socket: Socket) {
        socket.use {
            it.soTimeout = 15000
            val input = it.getInputStream(); val output = it.getOutputStream()
            try {
                val line = java.io.ByteArrayOutputStream()
                while (line.size() < 8192) { val b = input.read(); check(b >= 0) { "Missing request" }; if (b == 10) break; line.write(b) }
                check(line.size() < 8192) { "Request too long" }
                val request = JSONObject(line.toString("UTF-8"))
                check(request.optInt("version") == 1 && MessageDigest.isEqual(request.optString("token").toByteArray(), token.toByteArray())) { "Unauthorized adapter request" }
                check(request.getString("kind") == "saf") { "Provider not exposed" }
                val path = request.optString("path", "").let { value -> if (value == ".") "" else value }
                check(!path.startsWith('/') && !path.contains('\\') && !path.contains('\u0000') && (path.isEmpty() || path.split('/').none { part -> part.isEmpty() || part == "." || part == ".." })) { "Unsafe adapter path" }
                val ref = LocalFiles.Ref("saf", path)
                fun reply(value: JSONObject) { output.write((value.toString() + "\n").toByteArray(Charsets.UTF_8)); output.flush() }
                when (request.getString("operation")) {
                    "list" -> {
                        val all = local.list(ref); val offset = request.optInt("offset"); val limit = request.optInt("limit", 200)
                        check(offset >= 0 && offset <= all.size && limit in 1..500) { "Invalid listing bounds" }
                        val entries = all.drop(offset).take(limit).map { wireEntry(it) }
                        reply(JSONObject().put("ok", true).put("listing", JSONObject().put("entries", JSONArray(entries.map { JSONObject(it) })).put("next", if (offset + entries.size < all.size) (offset + entries.size).toString() else "")))
                    }
                    "stat" -> reply(JSONObject().put("ok", true).put("entry", JSONObject(wireEntry(local.stat(ref) + ("path" to if (path.isEmpty()) "." else path)))))
                    "read" -> {
                        val meta = local.stat(ref); check(meta["kind"] == "file") { "Not a regular file" }
                        val offset = request.optLong("offset"); val size = (meta["size"] as Number).toLong(); check(offset in 0..size) { "Invalid read offset" }
                        local.read(ref).use { stream ->
                            var remaining = offset
                            while (remaining > 0) { val skipped = stream.skip(remaining); if (skipped > 0) remaining -= skipped else { check(stream.read() >= 0) { "Source changed" }; remaining-- } }
                            reply(JSONObject().put("ok", true).put("bytes", size - offset))
                            val buffer = ByteArray(256 * 1024); var bytes = size - offset
                            while (bytes > 0) { val n = stream.read(buffer, 0, minOf(buffer.size.toLong(), bytes).toInt()); check(n > 0) { "Source changed" }; output.write(buffer, 0, n); bytes -= n }
                        }
                    }
                    else -> error("Unsupported adapter operation")
                }
            } catch (_: Exception) {
                try { output.write("{\"ok\":false,\"error\":\"document operation denied or failed\"}\n".toByteArray()); output.flush() } catch (_: Exception) {}
            }
        }
    }
    fun close() { closed = true; server.close(); workers.shutdownNow() }
}
