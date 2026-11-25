package dev.devicebridge.devicebridge

import android.app.Activity
import java.io.BufferedWriter
import java.io.File
import java.util.concurrent.Executors

/** One foreground terminal child, with frame I/O kept off the UI thread. */
internal class GuestTerminal(private val activity: Activity, private val emit: (String) -> Unit) {
    private val requests = Executors.newSingleThreadExecutor()
    private val streams = Executors.newCachedThreadPool()
    @Volatile private var child: Process? = null
    @Volatile private var closed = false
    private var writer: BufferedWriter? = null

    fun start(
        initial: String,
        subcommand: String = "guest-terminal",
        extraArgs: List<String> = emptyList(),
        finished: (Exception?) -> Unit,
    ) {
        requests.execute {
            try {
                check(child == null) { "An SSH shell is already open." }
                check(subcommand == "guest-terminal" || subcommand == "agent-terminal") {
                    "Unsupported terminal command."
                }
                val context = activity.applicationContext
                val executable = GoBinaryManager.resolve(context, "cli")
                val state = File(context.filesDir, "devicebridge").path
                val cmd = mutableListOf(
                    executable.path, "--state", state, "--tailnet-mode", "tsnet"
                )
                cmd.addAll(extraArgs)
                cmd.add(subcommand)
                cmd.add("-")
                val proc = ProcessBuilder(cmd).start()
                child = proc
                try {
                    writer = proc.outputStream.bufferedWriter()
                    send(initial)
                    streams.execute {
                        var message: String? = null
                        val errors = streams.submit<String> {
                            proc.errorStream.bufferedReader().use { it.readText().takeLast(4096) }
                        }
                        try {
                            proc.inputStream.bufferedReader().useLines { lines ->
                                for (line in lines) activity.runOnUiThread { if (!closed) emit(line) }
                            }
                            val code = proc.waitFor()
                            if (code != 0) message = errors.get().ifBlank { "SSH shell ended ($code)." }
                        } catch (_: Exception) {
                            message = "The SSH shell connection ended."
                        } finally {
                            if (!closed) requests.execute {
                                if (child === proc) {
                                    child = null
                                    writer = null
                                    val frame = org.json.JSONObject().put("state", "closed")
                                    message?.let { frame.put("error", it) }
                                    activity.runOnUiThread { if (!closed) emit(frame.toString()) }
                                }
                            }
                        }
                    }
                } catch (error: Exception) {
                    child = null
                    writer = null
                    proc.destroy()
                    throw error
                }
                activity.runOnUiThread { finished(null) }
            } catch (error: Exception) {
                activity.runOnUiThread { finished(error) }
            }
        }
    }

    private fun send(line: String) {
        check(line.toByteArray(Charsets.UTF_8).size < 65536 && !line.contains('\n')) { "Invalid terminal frame." }
        writer?.apply {
            write(line)
            newLine()
            flush()
        } ?: error("The SSH shell is closed.")
    }

    fun write(line: String, finished: (Exception?) -> Unit) {
        requests.execute {
            try {
                send(line)
                activity.runOnUiThread { finished(null) }
            } catch (error: Exception) {
                activity.runOnUiThread { finished(error) }
            }
        }
    }

    fun stop() {
        child?.destroy()
    }

    fun close() {
        closed = true
        stop()
        streams.shutdownNow()
        requests.shutdown()
    }
}
