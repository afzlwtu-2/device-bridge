package dev.devicebridge.devicebridge

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Process
import android.os.SystemClock
import android.system.Os
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/** Launches in the app's original UID, groups and sandbox through a compatible su. */
internal class DetachedTerminal(private val context: Context) {
    private val state = File(context.filesDir, "devicebridge")
    private val directory = File(state, "pt")
    private val validId = Regex("[A-Za-z0-9_-]{1,32}")

    private fun connect(id: String): LocalSocket {
        require(validId.matches(id)) { "Invalid terminal session ID." }
        val socket = LocalSocket()
        try {
            socket.connect(LocalSocketAddress(File(directory, "$id.sock").path, LocalSocketAddress.Namespace.FILESYSTEM))
            check(socket.peerCredentials.uid == Process.myUid()) { "Unexpected terminal supervisor identity." }
            socket.soTimeout = 1000
            return socket
        } catch (failure: Exception) {
            socket.close()
            throw failure
        }
    }

    private fun command(socket: LocalSocket, operation: String, request: JSONObject? = null) {
        val envelope = JSONObject().put("version", 1).put("operation", operation)
        if (request != null) envelope.put("request", request)
        socket.outputStream.write((envelope.toString() + "\n").toByteArray())
        socket.outputStream.flush()
    }

    fun ids(): List<String> = directory.list().orEmpty()
        .filter { it.endsWith(".sock") }
        .map { it.removeSuffix(".sock") }
        .filter { id -> validId.matches(id) && runCatching {
            connect(id).use { socket ->
                command(socket, "status")
                val response = JSONObject(socket.inputStream.bufferedReader().readLine() ?: "{}")
                response.optInt("version") == 1 && response.optString("state") == "available"
            }
        }.getOrDefault(false) }
        .sorted()

    fun stop(id: String) {
        runCatching { connect(id).use { command(it, "stop") } }
    }

    fun attach(id: String, initial: String, reattach: Boolean): LocalSocket {
        require(validId.matches(id)) { "Invalid terminal session ID." }
        val request = JSONObject(initial)
        val existing = runCatching { connect(id) }.getOrNull()
        if (existing != null) return sendAttach(existing, request)
        check(!reattach) { "This background terminal session has ended." }
        launch(id)
        val deadline = SystemClock.uptimeMillis() + 2500
        while (SystemClock.uptimeMillis() < deadline) {
            val socket = runCatching { connect(id) }.getOrNull()
            if (socket != null) return sendAttach(socket, request)
            Thread.sleep(50)
        }
        error("Background terminal startup timed out.")
    }

    private fun sendAttach(socket: LocalSocket, request: JSONObject): LocalSocket {
        try {
            command(socket, "attach", request)
            socket.soTimeout = 0
            return socket
        } catch (failure: Exception) {
            socket.close()
            throw failure
        }
    }

    private fun launch(id: String) {
        val cli = GoBinaryManager.bundled(context, "cli")
        check(cli.canExecute()) { "The bundled DeviceBridge CLI is unavailable." }
        val uid = Process.myUid().toString()
        val gid = Os.getgid().toString()
        val seLinuxPresent = File("/sys/fs/selinux").exists()
        val label = if (seLinuxPresent) {
            File("/proc/self/attr/current").readText().trim('\u0000', '\n', '\r', ' ')
                .also { check(it.isNotEmpty()) { "Empty SELinux security context." } }
        } else {
            "selinux-disabled"
        }
        val groups = File("/proc/self/status").useLines { lines ->
            lines.first { it.startsWith("Groups:") }.substringAfter(':').trim()
                .split(Regex("\\s+")).filter { it.isNotEmpty() }.map { it.toInt().toString() }
                .distinct()
        }
        val q: (String) -> String = { s -> "'" + s.replace("'", "'\"'\"'") + "'" }
        val envPrefix = "DEVICEBRIDGE_APP_PACKAGE=${q(context.packageName)} DEVICEBRIDGE_NATIVE_LIB_DIR=${q(context.applicationInfo.nativeLibraryDir)}"
        val command = envPrefix + " " + listOf(cli.path, "--state", state.path, "local-terminal-detached",
            "launch", id, uid, gid, groups.joinToString(" "), label)
            .joinToString(" ", prefix = "exec ") { q(it) }
        val common = buildList {
            add("su")
            if (seLinuxPresent) {
                add("-Z")
                add(label)
            }
            for (group in groups) {
                add("-G")
                add(group)
            }
            add("-g")
            add(gid)
        }
        // Pass uid before -c so MagiskSU switches UID/capabilities instead of passing uid to sh.
        for (flags in listOf(emptyList(), listOf("-d"))) {
            val nullDevice = File("/dev/null")
            val child = ProcessBuilder(common + flags + listOf(uid, "-c", command))
                .redirectInput(nullDevice).redirectOutput(nullDevice).redirectErrorStream(true).start()
            try {
                check(child.waitFor(4, TimeUnit.SECONDS)) { "Root terminal launcher timed out." }
                if (child.exitValue() == 0) return
            } finally {
                child.destroyForcibly()
            }
        }
        error("Root could not start the terminal with DeviceBridge's original sandbox permissions.")
    }
}
