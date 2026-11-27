package dev.devicebridge.devicebridge

import android.app.Activity
import android.util.Base64
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Multi-session local PTY shell manager (fish / bash / sh) targeting the app-private terminal prefix. */
internal class LocalTerminal(
    private val activity: Activity,
    private val allowDetached: () -> Boolean,
    private val emit: (String) -> Unit
) {
    private val requests = Executors.newSingleThreadExecutor()
    private val streams = Executors.newCachedThreadPool()
    private val sessions = ConcurrentHashMap<String, Session>()
    private val starts = ConcurrentHashMap<String, AtomicBoolean>()
    private val detached = DetachedTerminal(activity.applicationContext)
    @Volatile private var closed = false

    private class Session(
        val reader: BufferedReader,
        val writer: BufferedWriter,
        val closeTransport: () -> Unit,
        val process: Process? = null,
    )

    fun start(sessionId: String, initial: String, finished: (Exception?) -> Unit) {
        val cancelled = AtomicBoolean(false)
        starts.put(sessionId, cancelled)?.set(true)
        requests.execute {
            var startReplied = false
            try {
                check(!closed && !cancelled.get()) { "The terminal screen has closed." }
                sessions.remove(sessionId)?.closeTransport?.invoke()
                val reattach = JSONObject(initial).optBoolean("reattach")
                val detachedAllowed = allowDetached()
                check(!reattach || detachedAllowed) { "Background terminal persistence is unavailable." }
                if (!reattach) {
                    startReplied = true
                    activity.runOnUiThread { finished(null) }
                }
                if (!reattach && !TermuxBootstrap.isReady(activity.applicationContext)) {
                    val emitLine: (String) -> Unit = { line ->
                        val payload = "$line\r\n"
                        val frame = JSONObject().put("session_id", sessionId).put(
                            "data",
                            Base64.encodeToString(payload.toByteArray(Charsets.UTF_8), Base64.NO_WRAP),
                        )
                        activity.runOnUiThread { if (!closed) emit(frame.toString()) }
                    }
                    val emitProgress: (String, String, Long?, Long?) -> Unit = { phase, message, bytes, total ->
                        val frame = JSONObject()
                            .put("session_id", sessionId)
                            .put("state", "setup")
                            .put("phase", phase)
                            .put("message", message)
                        if (bytes != null) frame.put("bytes", bytes)
                        if (total != null) frame.put("total", total)
                        activity.runOnUiThread { if (!closed) emit(frame.toString()) }
                    }
                    try {
                        TermuxBootstrap.ensureReady(activity.applicationContext, emitLine, emitProgress,
                            active = { !closed && !cancelled.get() })
                        emitLine("")
                    } catch (setupError: Exception) {
                        if (closed || cancelled.get()) return@execute
                        emitLine("\r\n\u001b[33mTermux setup could not finish: ${setupError.message ?: setupError}\u001b[0m")
                        emitLine("Opening the Android shell. Reopen Terminal to retry setup.\r\n")
                    }
                    val launchingFrame = JSONObject()
                        .put("session_id", sessionId)
                        .put("state", "setup")
                        .put("phase", "launching")
                        .put("message", "Starting shell...")
                    activity.runOnUiThread { if (!closed) emit(launchingFrame.toString()) }
                }
                if (closed || cancelled.get()) return@execute
                val background = if (detachedAllowed) {
                    try {
                        val socket = detached.attach(sessionId, initial, reattach)
                        Session(socket.inputStream.bufferedReader(), socket.outputStream.bufferedWriter(), socket::close)
                    } catch (failure: Exception) {
                        if (reattach) throw failure
                        val message = "\r\nBackground terminal unavailable. This session runs while DeviceBridge is open.\r\n"
                        val frame = JSONObject().put("session_id", sessionId).put("data",
                            Base64.encodeToString(message.toByteArray(), Base64.NO_WRAP))
                        activity.runOnUiThread { if (!closed) emit(frame.toString()) }
                        null
                    }
                } else null
                val session = background ?: startAttached(initial)
                if (closed || cancelled.get()) {
                    session.closeTransport()
                    return@execute
                }
                sessions[sessionId] = session
                try {
                    streams.execute {
                        var message: String? = null
                        val proc = session.process
                        val errors = proc?.let {
                            streams.submit<String> {
                                it.errorStream.bufferedReader().use { reader -> reader.readText().takeLast(4096) }
                            }
                        }
                        try {
                            session.reader.useLines { lines ->
                                for (line in lines) {
                                    val tagged = try {
                                        JSONObject(line).put("session_id", sessionId).toString()
                                    } catch (_: Exception) {
                                        line
                                    }
                                    activity.runOnUiThread { if (!closed) emit(tagged) }
                                }
                            }
                            val code = proc?.waitFor()
                            if (code != null && code != 0) {
                                message = errors?.get().orEmpty().ifBlank { "Termux session ended ($code)." }
                            }
                        } catch (_: Exception) {
                            message = "The Termux session ended."
                        } finally {
                            if (!closed) requests.execute {
                                if (sessions.remove(sessionId, session)) {
                                    val frame = JSONObject()
                                        .put("session_id", sessionId)
                                        .put("state", "closed")
                                    message?.let { frame.put("error", it) }
                                    activity.runOnUiThread { if (!closed) emit(frame.toString()) }
                                }
                            }
                            runCatching { session.closeTransport() }
                        }
                    }
                } catch (error: Exception) {
                    sessions.remove(sessionId, session)
                    session.closeTransport()
                    throw error
                }
                if (!startReplied) {
                    startReplied = true
                    activity.runOnUiThread { finished(null) }
                }
            } catch (error: Exception) {
                if (!startReplied) {
                    activity.runOnUiThread { finished(error) }
                } else if (!closed) {
                    val frame = JSONObject()
                        .put("session_id", sessionId)
                        .put("state", "closed")
                        .put("error", error.message ?: "Unable to start terminal session.")
                    activity.runOnUiThread { if (!closed) emit(frame.toString()) }
                }
            } finally {
                starts.remove(sessionId, cancelled)
            }
        }
    }

    private fun startAttached(initial: String): Session {
        val context = activity.applicationContext
        val executable = GoBinaryManager.resolve(context, "cli")
        val state = File(context.filesDir, "devicebridge").path
        val pb = ProcessBuilder(executable.path, "--state", state, "local-terminal", "-")
        pb.environment()["DEVICEBRIDGE_APP_PACKAGE"] = context.packageName
        pb.environment()["DEVICEBRIDGE_NATIVE_LIB_DIR"] = context.applicationInfo.nativeLibraryDir
        val proc = pb.start()
        val session = Session(proc.inputStream.bufferedReader(), proc.outputStream.bufferedWriter(), proc::destroy, proc)
        try {
            sendTo(session, initial)
            return session
        } catch (error: Exception) {
            proc.destroy()
            throw error
        }
    }

    fun listDetached(result: (List<String>) -> Unit) {
        requests.execute {
            val ids = detached.ids()
            val allowed = ids.isNotEmpty() && allowDetached()
            if (!allowed) ids.forEach(detached::stop)
            activity.runOnUiThread { result(if (allowed) ids else emptyList()) }
        }
    }

    fun stopDetached() {
        requests.execute { detached.ids().forEach(detached::stop) }
    }

    fun hasSessions(result: (Boolean) -> Unit) {
        requests.execute {
            val active = sessions.isNotEmpty() || detached.ids().isNotEmpty()
            activity.runOnUiThread { result(active) }
        }
    }

    private fun sendTo(session: Session, line: String) {
        check(line.toByteArray(Charsets.UTF_8).size < 65536 && !line.contains('\n')) { "Invalid terminal frame." }
        synchronized(session.writer) {
            session.writer.write(line)
            session.writer.newLine()
            session.writer.flush()
        }
    }

    fun write(sessionId: String, line: String, finished: (Exception?) -> Unit) {
        requests.execute {
            try {
                val session = sessions[sessionId] ?: error("The Termux session is closed.")
                sendTo(session, line)
                activity.runOnUiThread { finished(null) }
            } catch (error: Exception) {
                activity.runOnUiThread { finished(error) }
            }
        }
    }

    fun stop(sessionId: String? = null) {
        if (sessionId == null) starts.values.forEach { it.set(true) } else starts[sessionId]?.set(true)
        requests.execute {
            if (sessionId != null) {
                sessions.remove(sessionId)?.closeTransport?.invoke()
                detached.stop(sessionId)
            } else {
                dropTransports()
                detached.ids().forEach(detached::stop)
            }
        }
    }

    private fun dropTransports() {
        for ((id, session) in sessions.entries) {
            if (sessions.remove(id, session)) runCatching { session.closeTransport() }
        }
    }

    fun close() {
        closed = true
        dropTransports()
        streams.shutdownNow()
        requests.shutdown()
    }
}
