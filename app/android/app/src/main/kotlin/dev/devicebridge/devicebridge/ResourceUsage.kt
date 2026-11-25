package dev.devicebridge.devicebridge

import android.os.Process
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.InputStream
import java.util.concurrent.TimeUnit

/** Samples only this Android UID, when the visible Home screen requests status. */
internal class ResourceUsage {
    private data class ProcessSample(val name: String, val start: Long, val cpuMs: Double)

    private val uid = Process.myUid()
    private val pid = Process.myPid()
    private val ticksPerSecond = runCatching { Os.sysconf(OsConstants._SC_CLK_TCK) }.getOrDefault(0L)
    private var previous = emptyMap<Int, ProcessSample>()
    private var previousMs = 0L
    private var previousUiCpuMs = 0L
    private var batterySampleMs = -60_000L
    private var batterySample = emptyMap<String, Any>()
    private var proxySampleMs = -6_000L
    private var proxySampleKey: Pair<Int, Set<Int>>? = null
    private var proxySample: Set<Int>? = null

    fun trafficConnections(filesDir: File, rootDiagnostics: Boolean): Map<String, Any?> {
        val children = readProcesses()
        val sockets = mutableMapOf<Int, MutableList<Map<String, Any?>>>()
        val pidPattern = Regex("""\bpid=(\d+)""")
        val uidPattern = Regex("""\buid:(\d+)""")
        val received = Regex("""\bbytes_received:(\d+)""")
        val sent = Regex("""\bbytes_sent:(\d+)""")
        val args = listOf("ss", "-H", "-tunaipe")
        val collect: (InputStream) -> Boolean = { input ->
            var owners = emptySet<Int>()
            var peer = ""
            var rx: Long? = null
            var tx: Long? = null
            var visible = false
            fun flush() {
                if (peer.isNotEmpty() && !peer.endsWith(":*")) {
                    for (owner in owners) {
                        val list = sockets.getOrPut(owner) { mutableListOf() }
                        if (list.size < 64) {
                            list.add(mapOf("peer" to peer, "bytes_received" to rx, "bytes_sent" to tx))
                        }
                    }
                }
                rx = null
                tx = null
            }
            input.bufferedReader().lineSequence().forEach { line ->
                val text = line.trim()
                if (text.startsWith("tcp ") || text.startsWith("udp ")) {
                    flush()
                    val socketUid = uidPattern.find(text)?.groupValues?.get(1)?.toIntOrNull()
                    owners = if (socketUid == null || socketUid == uid) {
                        pidPattern.findAll(text).mapNotNull { it.groupValues[1].toIntOrNull() }
                            .filter { owner ->
                                (owner == pid || owner in children) &&
                                    runCatching { Os.stat("/proc/$owner").st_uid == uid }.getOrDefault(false)
                            }.toSet()
                    } else emptySet()
                    peer = text.split(Regex("\\s+"), limit = 7).getOrNull(5).orEmpty()
                    visible = visible || owners.isNotEmpty()
                }
                if (owners.isNotEmpty()) {
                    received.find(text)?.groupValues?.get(1)?.toLongOrNull()?.let { rx = it }
                    sent.find(text)?.groupValues?.get(1)?.toLongOrNull()?.let { tx = it }
                }
            }
            flush()
            visible
        }
        var visible = runProcessRead(args, collect) == true
        if (!visible && rootDiagnostics) {
            sockets.clear()
            visible = runRootRead("test \"\$(id -u)\" = 0 && ss -H -tunaipe", collect) == true
        }
        val termuxPath = File(filesDir, "terminal").absolutePath + "/"
        val processes = (children.mapValues { it.value.name } + (pid to "DeviceBridge"))
            .entries.sortedBy { it.key }.take(128).map { (owner, name) ->
                val exe = runCatching { Os.readlink("/proc/$owner/exe") }.getOrDefault("")
                val cwd = runCatching { Os.readlink("/proc/$owner/cwd") }.getOrDefault("")
                val group = when {
                    owner == pid || name.startsWith("bridge-agent") || name.startsWith("agent_") ||
                        exe.substringAfterLast('/') == "libbridge_agent.so" -> "app"
                    exe.startsWith(termuxPath) || cwd.startsWith(termuxPath) -> "termux"
                    else -> "bundled"
                }
                mapOf("pid" to owner, "name" to name, "group" to group, "connections" to sockets[owner].orEmpty())
            }
        return mapOf("processes" to processes, "socket_access" to visible)
    }

    @Synchronized
    fun sample(): Map<String, Any?> {
        val now = SystemClock.uptimeMillis()
        val uiCpuMs = Process.getElapsedCpuTime()
        val elapsed = now - previousMs
        val current = if (ticksPerSecond > 0) readProcesses() else emptyMap()
        val comparable = previousMs != 0L && elapsed in 1..12_000
        val processes = if (comparable) current.mapNotNull { (childPid, process) ->
            val old = previous[childPid]?.takeIf { it.start == process.start } ?: return@mapNotNull null
            val delta = process.cpuMs - old.cpuMs
            if (delta < 0) return@mapNotNull null
            Pair(process.name, 100 * delta / elapsed)
        } else emptyList()
        val appCpu = if (comparable && uiCpuMs >= previousUiCpuMs) {
            100.0 * (uiCpuMs - previousUiCpuMs) / elapsed
        } else null
        previous = current
        previousMs = now
        previousUiCpuMs = uiCpuMs
        return mapOf(
            "app_cpu_percent" to appCpu,
            "child_cpu_percent" to processes.takeIf { it.isNotEmpty() }?.sumOf { it.second },
            "visible_processes" to current.size,
            "processes" to processes.sortedByDescending { it.second }.take(8)
                .map { (name, cpu) -> mapOf("name" to name, "cpu_percent" to cpu) }
        )
    }

    private fun readProcesses(): Map<Int, ProcessSample> {
        val result = mutableMapOf<Int, ProcessSample>()
        for (entry in File("/proc").list().orEmpty()) {
            val childPid = entry.toIntOrNull() ?: continue
            if (childPid == pid) continue
            try {
                if (Os.stat("/proc/$entry").st_uid != uid) continue
                val stat = File("/proc/$entry/stat").readText()
                val start = stat.indexOf('(')
                val end = stat.lastIndexOf(')')
                if (start < 0 || end <= start) continue
                val fields = stat.substring(end + 1).trim().split(' ')
                val user = fields.getOrNull(11)?.toLongOrNull() ?: continue
                val kernel = fields.getOrNull(12)?.toLongOrNull() ?: continue
                val started = fields.getOrNull(19)?.toLongOrNull() ?: continue
                val name = stat.substring(start + 1, end).filterNot { it.isISOControl() }
                result[childPid] = ProcessSample(name, started, (user + kernel) * 1000.0 / ticksPerSecond)
            } catch (_: Exception) {
                // A process may exit or be hidden by Android before the read.
            }
        }
        return result
    }

    @Synchronized
    fun batteryDiagnostics(packageName: String, enabled: Boolean): Map<String, Any> {
        if (!enabled) {
            batterySample = emptyMap()
            batterySampleMs = -60_000L
            return batterySample
        }
        val now = SystemClock.elapsedRealtime()
        if (now - batterySampleMs < 60_000L) return batterySample
        batterySampleMs = now
        val cmd = "dumpsys -t 2 batterystats -c '$packageName'"
        batterySample = runRootRead(cmd) { input ->
            val stats = mutableMapOf<String, Any>()
            var alarmCount = 0L
            var verifiedReport = false
            input.bufferedReader().forEachLine { line ->
                val fields = line.split(',')
                if (fields.getOrNull(0)?.toIntOrNull() == null) return@forEachLine
                if (fields.getOrNull(3) == "vers") verifiedReport = true
                if (fields.getOrNull(1)?.toIntOrNull() != uid || fields.getOrNull(2) != "l") return@forEachLine
                when (fields.getOrNull(3)) {
                    "wua" -> fields.lastOrNull()?.toLongOrNull()?.let { alarmCount += it }
                    "awl" -> fields.getOrNull(4)?.toLongOrNull()?.let { stats["partial_wake_lock_ms"] = it }
                    "pwi" -> if (fields.getOrNull(4) == "uid") {
                        fields.getOrNull(5)?.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 }
                            ?.let { stats["estimated_mah"] = it }
                    }
                }
            }
            if (verifiedReport) stats["wakeup_alarms"] = alarmCount
            stats.toMap()
        } ?: emptyMap()
        return batterySample
    }

    /** Resolve TCP client UIDs from the outgoing loopback socket, when visible. */
    @Synchronized
    fun proxyClientUids(serverPort: Int, clientPorts: Set<Int>): Set<Int>? {
        if (serverPort !in 1024..65535 || clientPorts.isEmpty()) return emptySet()
        val now = SystemClock.elapsedRealtime()
        val key = serverPort to clientPorts
        if (now - proxySampleMs < 6_000L) {
            return proxySample.takeIf { proxySampleKey == key }
        }
        proxySampleMs = now
        proxySampleKey = key
        proxySample = runRootRead("cat /proc/net/tcp") { input ->
            val uids = mutableSetOf<Int>()
            val remote = "0100007F:%04X".format(serverPort)
            input.bufferedReader().forEachLine { line ->
                val fields = line.trim().split(Regex("\\s+"), limit = 9)
                if (fields.size < 8 || fields[2] != remote || fields[3] != "01") return@forEachLine
                val source = fields[1]
                if (!source.startsWith("0100007F:")) return@forEachLine
                val port = source.substringAfter(':').toIntOrNull(16)
                if (port in clientPorts) fields[7].toIntOrNull()?.let(uids::add)
            }
            uids.toSet()
        }
        return proxySample
    }

    private fun <T> runRootRead(command: String, read: (InputStream) -> T): T? {
        return runProcessRead(listOf("su", "-c", command), read)
    }

    private fun <T> runProcessRead(args: List<String>, read: (InputStream) -> T): T? {
        val process = runCatching { ProcessBuilder(args).redirectErrorStream(true).start() }
            .getOrNull() ?: return null
        val output = java.util.concurrent.FutureTask { process.inputStream.use(read) }
        val reader = Thread(output, "DeviceBridge diagnostics").apply { isDaemon = true; start() }
        return try {
            if (process.waitFor(3, TimeUnit.SECONDS) && process.exitValue() == 0) {
                output.get(250, TimeUnit.MILLISECONDS)
            } else null
        } catch (_: Exception) {
            null
        } finally {
            process.destroyForcibly()
            output.cancel(true)
            reader.interrupt()
        }
    }
}
