package dev.devicebridge.devicebridge

import android.content.Context
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Ensures the app-private Termux environment has a verified base bootstrap,
 * default shells/tools (fish, tmux, openssh, starship, fastfetch), and configs.
 */
internal object TermuxBootstrap {
    private val setupLock = Any()
    private val TAG_PATTERN = Regex("""/termux/termux-packages/releases/tag/([^"/?#]+)""")
    private const val RELEASES_LATEST = "https://github.com/termux/termux-packages/releases/latest"
    private const val MAX_BOOTSTRAP_BYTES = 128L * 1024L * 1024L

    private fun termuxArch(): String {
        val abi = Build.SUPPORTED_ABIS.firstOrNull().orEmpty()
        return when {
            abi.startsWith("arm64") -> "aarch64"
            abi.startsWith("x86_64") -> "x86_64"
            abi.startsWith("armeabi") -> "arm"
            abi.startsWith("x86") -> "i686"
            else -> "aarch64"
        }
    }

    private fun prefix(context: Context) = File(context.filesDir, "terminal/files/usr")

    private fun hasBase(context: Context) = File(prefix(context), "bin/bash").canExecute() &&
        File(prefix(context), "bin/apt-get").canExecute()

    fun isReady(context: Context) = hasBase(context) &&
        File(prefix(context), "bin/db-ssh-shell").canExecute() &&
        File(prefix(context), ".devicebridge-configured-v4").isFile

    fun hasSshClient(context: Context) = isReady(context) && File(prefix(context), "bin/ssh").canExecute()

    fun hasOpenSsh(context: Context) = isReady(context) &&
        File(prefix(context), "bin/sshd").canExecute() &&
        File(prefix(context), "etc/ssh/ssh_host_ed25519_key").isFile

    fun ensureReady(
        context: Context,
        emitLine: (String) -> Unit,
        onProgress: (phase: String, message: String, bytes: Long?, total: Long?) -> Unit = { _, _, _, _ -> },
        mode: String = "base",
        active: () -> Boolean = { true },
    ) {
        if (mode == "base" && isReady(context) || mode == "ssh-client" && hasSshClient(context)) return
        synchronized(setupLock) {
            if (mode == "base" && isReady(context) || mode == "ssh-client" && hasSshClient(context)) return
            val deadline = android.os.SystemClock.elapsedRealtime() + TimeUnit.MINUTES.toMillis(10)
            fun inTime() = active() && android.os.SystemClock.elapsedRealtime() < deadline
            fun checkActive() = check(inTime()) { if (active()) "Terminal setup timed out." else "Terminal setup cancelled." }
            checkActive()
            val cacheDir = File(context.cacheDir, "termux-bootstrap").apply { mkdirs() }
            val arch = termuxArch()
            onProgress("prepare", "Preparing Terminal environment...", null, null)
            val archive = if (hasBase(context)) null else {
                downloadVerifiedBootstrap(arch, cacheDir, emitLine, onProgress, ::checkActive)
            }

            try {
                checkActive()
                onProgress("configure", "Configuring Terminal...", null, null)
                val executable = GoBinaryManager.resolve(context, "cli")
                val state = File(context.filesDir, "devicebridge").path
                val command = mutableListOf(executable.path, "--state", state, "termux-setup", "--mode", mode)
                if (archive != null) {
                    command.addAll(listOf("--archive", archive.file.path, "--release-sha256", archive.digest))
                }
                val pb = ProcessBuilder(command).redirectErrorStream(true)
                pb.environment()["DEVICEBRIDGE_APP_PACKAGE"] = context.packageName
                pb.environment()["DEVICEBRIDGE_NATIVE_LIB_DIR"] = context.applicationInfo.nativeLibraryDir
                val proc = pb.start()
                val watchdog = Executors.newSingleThreadScheduledExecutor()
                val stopped = AtomicBoolean(false)
                watchdog.scheduleAtFixedRate({
                    if (!inTime() && proc.isAlive) {
                        if (stopped.getAndSet(true)) proc.destroyForcibly() else proc.destroy()
                    }
                }, 250L, 250L, TimeUnit.MILLISECONDS)
                try {
                    proc.inputStream.bufferedReader().useLines { lines ->
                        lines.filter { it.isNotBlank() }.forEach { line ->
                            if (inTime()) {
                                emitLine(line)
                                val phase = when {
                                    line.startsWith("Extracting ") -> "extract"
                                    line.startsWith("Updating ") -> "apt_update"
                                    line.startsWith("Installing ") -> "apt_install"
                                    else -> "setup"
                                }
                                onProgress(phase, line.trim(), null, null)
                            }
                        }
                    }
                    check(proc.waitFor(5, TimeUnit.SECONDS)) { "Terminal setup did not exit." }
                    checkActive()
                    check(proc.exitValue() == 0) { "Terminal setup exited with code ${proc.exitValue()}." }
                    check(isReady(context)) { "Terminal base setup is incomplete." }
                    if (mode == "ssh-client") check(hasSshClient(context)) { "OpenSSH client setup is incomplete." }
                    if (mode == "openssh") check(hasOpenSsh(context)) { "OpenSSH setup is incomplete." }
                } finally {
                    if (proc.isAlive) proc.destroyForcibly()
                    watchdog.shutdownNow()
                }
            } finally {
                archive?.file?.delete()
            }
        }
    }

    private data class VerifiedBootstrap(val file: File, val digest: String)

    private fun downloadVerifiedBootstrap(
        arch: String,
        cacheDir: File,
        emitLine: (String) -> Unit,
        onProgress: (phase: String, message: String, bytes: Long?, total: Long?) -> Unit,
        checkActive: () -> Unit,
    ): VerifiedBootstrap {
        onProgress("resolve", "Resolving latest Termux release...", null, null)
        emitLine("Resolving latest Termux bootstrap release...")
        val tag = resolveLatestTag()
        val assetName = "bootstrap-$arch.zip"
        onProgress("verify_manifest", "Checking SHA-256 manifest ($tag)...", null, null)
        emitLine("Verifying SHA-256 checksum ($tag)...")
        val expectedSha = resolveAssetSha256(tag, assetName)
        val encodedTag = tag.replace("+", "%2B")
        val assetUrl = URI("https://github.com/termux/termux-packages/releases/download/$encodedTag/$assetName")

        val part = File.createTempFile("bootstrap-$arch-", ".zip", cacheDir)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var lastReportedMb = -1L
            var lastProgressMs = 0L
            fetch(assetUrl) { conn ->
                val total = conn.contentLengthLong
                onProgress(
                    "download",
                    "Downloading $assetName...",
                    0L,
                    if (total > 0) total else null,
                )
                conn.inputStream.use { input ->
                    part.outputStream().buffered().use { output ->
                        val buf = ByteArray(64 * 1024)
                        var copied = 0L
                        while (true) {
                            checkActive()
                            val n = input.read(buf)
                            if (n < 0) break
                            copied += n
                            check(copied <= MAX_BOOTSTRAP_BYTES) { "Termux bootstrap exceeds size limit." }
                            digest.update(buf, 0, n)
                            output.write(buf, 0, n)
                            val now = android.os.SystemClock.elapsedRealtime()
                            val copiedMb = String.format(Locale.US, "%.1f", copied / (1024.0 * 1024.0))
                            val totalMb = if (total > 0) String.format(Locale.US, "%.1f", total / (1024.0 * 1024.0)) else null
                            if (now - lastProgressMs >= 250L || (total > 0 && copied == total)) {
                                lastProgressMs = now
                                val msg = if (totalMb != null) {
                                    "Downloading $assetName ($copiedMb / $totalMb MiB)"
                                } else {
                                    "Downloading $assetName ($copiedMb MiB)"
                                }
                                onProgress("download", msg, copied, if (total > 0) total else null)
                            }
                            val mb = copied / (2L * 1024L * 1024L)
                            if (mb != lastReportedMb) {
                                lastReportedMb = mb
                                if (totalMb != null) {
                                    emitLine("  Downloading $assetName: $copiedMb / $totalMb MiB")
                                } else {
                                    emitLine("  Downloading $assetName: $copiedMb MiB")
                                }
                            }
                        }
                    }
                }
            }
            val actualSha = digest.digest().joinToString("") { "%02x".format(it) }
            check(actualSha.equals(expectedSha, ignoreCase = true)) {
                "Termux bootstrap SHA-256 mismatch."
            }
            return VerifiedBootstrap(part, expectedSha)
        } catch (e: Exception) {
            part.delete()
            throw e
        }
    }

    private fun resolveLatestTag(): String {
        val latest = URI(RELEASES_LATEST)
        val conn = open(latest)
        try {
            conn.instanceFollowRedirects = false
            conn.connectTimeout = 15_000
            conn.readTimeout = 20_000
            val code = conn.responseCode
            val loc = conn.getHeaderField("Location") ?: ""
            val uri = if (code in 300..399 && loc.isNotBlank()) latest.resolve(loc) else null
            check(uri?.scheme == "https" && uri.host == "github.com") { "Unexpected Termux release source." }
            val match = TAG_PATTERN.matchEntire(uri.path)
                ?: error("Could not resolve latest Termux bootstrap release.")
            val tag = match.groupValues[1]
            check(tag.matches(Regex("[A-Za-z0-9._+-]+"))) { "Unexpected Termux release tag." }
            return tag
        } finally {
            conn.disconnect()
        }
    }

    private fun resolveAssetSha256(tag: String, assetName: String): String {
        val encodedTag = tag.replace("+", "%2B")
        val expanded = URI("https://github.com/termux/termux-packages/releases/expanded_assets/$encodedTag")
        val html = fetch(expanded) { conn ->
            val out = ByteArrayOutputStream()
            conn.inputStream.use { copyBounded(it, out, 2L * 1024L * 1024L) }
            out.toString(Charsets.UTF_8.name())
        }
        val escaped = Regex.escape(assetName)
        val pattern = Regex("""$escaped[\s\S]{0,1600}?sha256:([0-9a-fA-F]{64})""")
        return pattern.find(html)?.groupValues?.get(1)?.lowercase(Locale.ROOT)
            ?: error("Could not verify SHA-256 checksum for $assetName.")
    }

    private fun <T> fetch(address: URI, read: (HttpURLConnection) -> T): T {
        var url = address
        repeat(6) {
            val conn = open(url)
            try {
                conn.instanceFollowRedirects = false
                conn.connectTimeout = 15_000
                conn.readTimeout = 60_000
                val code = conn.responseCode
                if (code == 200) return read(conn)
                if (code in 300..399) {
                    val loc = conn.getHeaderField("Location") ?: error("Empty redirect while fetching $url")
                    url = url.resolve(loc)
                } else {
                    error("HTTP $code while fetching Termux asset.")
                }
            } finally {
                conn.disconnect()
            }
        }
        error("Too many redirects while fetching Termux asset.")
    }

    private fun open(uri: URI): HttpURLConnection {
        check(uri.scheme == "https") { "HTTPS required for Termux bootstrap." }
        return (uri.toURL().openConnection() as HttpURLConnection).apply {
            setRequestProperty("User-Agent", "DeviceBridge")
        }
    }

    private fun copyBounded(input: InputStream, output: ByteArrayOutputStream, limit: Long) {
        val buf = ByteArray(16 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            total += n
            check(total <= limit) { "Response exceeded limit." }
            output.write(buf, 0, n)
        }
    }
}
