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
import java.util.concurrent.TimeUnit

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

    fun isReady(context: Context): Boolean {
        val usr = File(context.filesDir, "terminal/files/usr/bin")
        val bash = File(usr, "bash")
        val fish = File(usr, "fish")
        val starship = File(usr, "starship")
        return bash.canExecute() && fish.canExecute() && starship.canExecute()
    }

    fun ensureReady(context: Context, emitLine: (String) -> Unit) {
        if (isReady(context)) return
        synchronized(setupLock) {
            if (isReady(context)) return
            val termRoot = File(context.filesDir, "terminal")
            val usrBin = File(termRoot, "files/usr/bin")
            val cacheDir = File(termRoot, "cache").apply { mkdirs() }
            val arch = termuxArch()
            val bash = File(usrBin, "bash")
            val staged = File(cacheDir, "bootstrap-$arch.zip")
            val preStaged = File("/data/local/tmp/db-bootstrap-$arch.zip")

            var downloadedPath: String? = null
            if (!bash.canExecute()) {
                if (preStaged.isFile && preStaged.length() > 0) {
                    downloadedPath = preStaged.absolutePath
                } else if (!staged.isFile || staged.length() == 0L) {
                    emitLine("First-time Terminal setup: downloading Termux bootstrap ($arch)...")
                    downloadedPath = downloadVerifiedBootstrap(arch, staged, emitLine).absolutePath
                } else {
                    downloadedPath = staged.absolutePath
                }
            }

            val executable = GoBinaryManager.resolve(context, "cli")
            val state = File(context.filesDir, "devicebridge").path
            val pb = ProcessBuilder(executable.path, "--state", state, "termux-setup")
            pb.environment()["DEVICEBRIDGE_APP_PACKAGE"] = context.packageName
            pb.environment()["DEVICEBRIDGE_NATIVE_LIB_DIR"] = context.applicationInfo.nativeLibraryDir
            if (downloadedPath != null) {
                pb.environment()["DEVICEBRIDGE_BOOTSTRAP_ZIP"] = downloadedPath
            }
            pb.redirectErrorStream(true)
            val proc = pb.start()
            try {
                proc.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        if (line.isNotBlank()) emitLine(line)
                    }
                }
                check(proc.waitFor(10, TimeUnit.MINUTES)) { "Termux setup timed out." }
                check(proc.exitValue() == 0) { "Termux package setup exited with code ${proc.exitValue()}." }
            } finally {
                if (proc.isAlive) proc.destroyForcibly()
            }
        }
    }

    private fun downloadVerifiedBootstrap(arch: String, destination: File, emitLine: (String) -> Unit): File {
        val tag = resolveLatestTag()
        val assetName = "bootstrap-$arch.zip"
        val expectedSha = resolveAssetSha256(tag, assetName)
        val encodedTag = tag.replace("+", "%2B")
        val assetUrl = URI("https://github.com/termux/termux-packages/releases/download/$encodedTag/$assetName")

        val part = File(destination.parentFile, "${destination.name}.part")
        part.delete()
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var lastReportedMb = -1L
            fetch(assetUrl) { conn ->
                val total = conn.contentLengthLong
                conn.inputStream.use { input ->
                    part.outputStream().buffered().use { output ->
                        val buf = ByteArray(64 * 1024)
                        var copied = 0L
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            copied += n
                            check(copied <= MAX_BOOTSTRAP_BYTES) { "Termux bootstrap exceeds size limit." }
                            digest.update(buf, 0, n)
                            output.write(buf, 0, n)
                            val mb = copied / (4L * 1024L * 1024L)
                            if (mb != lastReportedMb) {
                                lastReportedMb = mb
                                val copiedMb = String.format(Locale.US, "%.1f", copied / (1024.0 * 1024.0))
                                if (total > 0) {
                                    val totalMb = String.format(Locale.US, "%.1f", total / (1024.0 * 1024.0))
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
            destination.delete()
            check(part.renameTo(destination)) { "Could not finalize downloaded bootstrap archive." }
            return destination
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
            val match = TAG_PATTERN.find(uri?.toString().orEmpty())
                ?: error("Could not resolve latest Termux bootstrap release.")
            return match.groupValues[1]
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
