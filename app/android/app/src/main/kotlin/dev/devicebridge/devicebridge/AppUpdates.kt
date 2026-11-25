package dev.devicebridge.devicebridge

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.Locale
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

internal class AppUpdates(
    private val activity: Activity,
    private val worker: Executor,
    private val rootEnabled: () -> Boolean,
    private val checksum: (InputStream) -> String,
) {
    private data class Release(val version: String, val apkName: String, val size: Long) {
        fun asset(name: String) = "https://github.com/$REPO/releases/download/v$version/$name"
    }

    private data class Install(val apk: File, val reply: MethodChannel.Result)

    private var offered: Release? = null
    private var installing = false
    private var installer: Install? = null

    fun version(): String {
        val installed = installedPackage()
        return "${installed.versionName.orEmpty()} (${installed.longVersionCode})"
    }

    fun check(manual: Boolean, reply: MethodChannel.Result) {
        if (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            if (manual) reply.error("debug_build", "GitHub updates require the release-signed app.", null)
            else reply.success(null)
            return
        }
        worker.execute {
            try {
                val release = latestRelease(installedPackage().versionName.orEmpty())
                activity.runOnUiThread {
                    offered = release
                    reply.success(release?.let { mapOf("version" to it.version, "bytes" to it.size) })
                }
            } catch (error: Exception) {
                activity.runOnUiThread { reply.error("update_check_failed", error.message, null) }
            }
        }
    }

    fun download(version: String?, reply: MethodChannel.Result) {
        val release = offered
        if (release == null || release.version != version || installing) {
            reply.error("update_unavailable", "Check for updates again before downloading.", null)
            return
        }
        installing = true
        worker.execute {
            var apk: File? = null
            try {
                apk = downloadVerified(release)
                if (rootEnabled()) {
                    installAsRoot(apk)
                    apk.delete()
                    activity.runOnUiThread {
                        installing = false
                        reply.success(true)
                    }
                } else {
                    val pending = Install(apk, reply)
                    activity.runOnUiThread { openInstaller(pending) }
                }
            } catch (error: Exception) {
                apk?.delete()
                activity.runOnUiThread {
                    installing = false
                    reply.error("update_install_failed", error.message, null)
                }
            }
        }
    }

    private fun latestRelease(current: String): Release? {
        val local = versionParts(current) ?: error("The installed version is not recognized.")
        val json = readText("https://api.github.com/repos/$REPO/releases/latest", 2L * 1024 * 1024, true)
            ?.let(::JSONObject) ?: return null
        val tag = json.getString("tag_name")
        if (!tag.startsWith("v") || json.optBoolean("draft") || json.optBoolean("prerelease")) return null
        val version = tag.removePrefix("v")
        val remote = versionParts(version) ?: return null
        val firstDifference = remote.zip(local).firstOrNull { (next, old) -> next != old } ?: return null
        if (firstDifference.first < firstDifference.second) return null

        val assets = json.getJSONArray("assets")
        val sizes = (0 until assets.length()).map { assets.getJSONObject(it) }
            .filter { it.optString("state") == "uploaded" }
            .associate { it.getString("name") to it.getLong("size") }
        val apk = (Build.SUPPORTED_ABIS.map { "devicebridge-android-$it.apk" } +
            "devicebridge-android-universal.apk").firstOrNull { (sizes[it] ?: 0L) in 1L..MAX_APK_BYTES }
            ?: error("GitHub has no compatible APK for this release.")
        check((sizes["CHECKSUMS.xxh64"] ?: 0L) in 1L..CHECKSUM_LIMIT) { "The release checksum file is unavailable." }
        return Release(version, apk, sizes.getValue(apk))
    }

    private fun versionParts(value: String): List<Int>? {
        if (!STABLE_VERSION.matches(value)) return null
        return value.split('.').map { it.toIntOrNull() ?: return null }
    }

    private fun downloadVerified(release: Release): File {
        val checksums = readText(release.asset("CHECKSUMS.xxh64"), CHECKSUM_LIMIT).orEmpty()
        val expected = checksums.lineSequence().firstNotNullOfOrNull { line ->
            val match = CHECKSUM_LINE.matchEntire(line.trimEnd()) ?: return@firstNotNullOfOrNull null
            match.groupValues[1].lowercase(Locale.ROOT).takeIf { match.groupValues[2] == release.apkName }
        } ?: error("The release does not list an XXH64 checksum for this APK.")

        val directory = File(activity.cacheDir, "updates")
        check(directory.isDirectory || directory.mkdirs()) { "Cannot open the update cache." }
        // Any prior file belongs to a completed or interrupted update in this app.
        directory.listFiles()?.filter { it.name.startsWith("devicebridge-") && it.extension == "apk" }?.forEach { it.delete() }
        val apk = File.createTempFile("devicebridge-", ".apk", directory)
        try {
            val bytes = apk.outputStream().buffered().use { output ->
                fetch(release.asset(release.apkName)) { copyBounded(it, output, release.size) }
            }
            check(bytes == release.size) { "The update download was incomplete." }
            check(checksum(apk.inputStream()) == expected) { "The downloaded APK failed XXH64 verification." }
            val installed = installedPackage()
            val candidate = activity.packageManager.getPackageArchiveInfo(apk.path, PackageManager.GET_SIGNING_CERTIFICATES)
                ?: error("Android could not verify the update APK.")
            check(candidate.packageName == activity.packageName && candidate.versionName == release.version &&
                candidate.longVersionCode > installed.longVersionCode) { "The APK does not match this app and release version." }
            val signers = installed.signingInfo?.apkContentsSigners?.toSet().orEmpty()
            check(signers.isNotEmpty() && candidate.signingInfo?.apkContentsSigners?.toSet() == signers) {
                "The update is signed with a different key from the installed app."
            }
            return apk
        } catch (error: Exception) {
            apk.delete()
            throw error
        }
    }

    private fun installedPackage(): PackageInfo =
        activity.packageManager.getPackageInfo(activity.packageName, PackageManager.GET_SIGNING_CERTIFICATES)

    private fun installAsRoot(apk: File) {
        val log = File.createTempFile("update-install-", ".log", activity.cacheDir)
        try {
            // Let the root shell feed Android a pipe. The system installer
            // therefore has no need to open a file from the app's sandbox.
            val command = "test \"\$(id -u)\" = 0 && /system/bin/cat | /system/bin/pm install -r -S ${apk.length()} -"
            val child = ProcessBuilder("su", "-c", command)
                .redirectInput(apk).redirectErrorStream(true).redirectOutput(log).start()
            try {
                check(child.waitFor(120, TimeUnit.SECONDS)) { "Android timed out installing the update." }
                val response = log.readText().trim()
                check(child.exitValue() == 0 && response.lineSequence().any { it == "Success" }) {
                    response.ifBlank { "Android declined the Root installation." }
                }
            } finally {
                if (child.isAlive) child.destroyForcibly()
            }
        } finally {
            log.delete()
        }
    }

    private fun openInstaller(pending: Install, returnedFromSettings: Boolean = false) {
        installer = pending
        try {
            if (!activity.packageManager.canRequestPackageInstalls()) {
                if (returnedFromSettings) {
                    finishInstaller(false)
                    return
                }
                activity.startActivityForResult(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")),
                    INSTALL_PERMISSION,
                )
                return
            }
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.files", pending.apk)
            val install = Intent(Intent.ACTION_INSTALL_PACKAGE, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                .putExtra(Intent.EXTRA_RETURN_RESULT, true)
            activity.startActivityForResult(install, INSTALL_APK)
        } catch (error: Exception) {
            finishInstaller(false, error.message ?: "Android could not open the package installer.")
        }
    }

    fun handle(request: Int, resultCode: Int): Boolean {
        when (request) {
            INSTALL_PERMISSION -> installer?.let { openInstaller(it, returnedFromSettings = true) }
            INSTALL_APK -> finishInstaller(resultCode == Activity.RESULT_OK)
            else -> return false
        }
        return true
    }

    private fun finishInstaller(installed: Boolean, error: String? = null) {
        val pending = installer ?: return
        installer = null
        installing = false
        pending.apk.delete()
        if (error != null) pending.reply.error("update_install_failed", error, null)
        else pending.reply.success(installed)
    }

    private fun readText(url: String, maxBytes: Long, allowMissing: Boolean = false): String? =
        fetch(url, allowMissing) { input ->
            val data = ByteArrayOutputStream()
            copyBounded(input, data, maxBytes)
            data.toString(Charsets.UTF_8.name())
        }

    private fun <T> fetch(address: String, allowMissing: Boolean = false, read: (InputStream) -> T): T? {
        var url = URI(address)
        repeat(5) {
            check(url.scheme == "https" && url.host in DOWNLOAD_HOSTS && url.userInfo == null && url.port == -1) {
                "GitHub redirected to an unexpected download host."
            }
            val connection = url.toURL().openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 10_000
                connection.readTimeout = 20_000
                connection.setRequestProperty("User-Agent", "DeviceBridge-Android")
                if (url.host == "api.github.com") {
                    connection.setRequestProperty("Accept", "application/vnd.github+json")
                }
                when (val status = connection.responseCode) {
                    200 -> return connection.inputStream.use(read)
                    301, 302, 303, 307, 308 -> url = url.resolve(connection.getHeaderField("Location")
                        ?: error("GitHub returned a redirect without a destination."))
                    404 -> if (allowMissing) return null else error("The release asset is unavailable.")
                    else -> error("GitHub returned HTTP $status.")
                }
            } finally {
                connection.disconnect()
            }
        }
        error("GitHub returned too many redirects.")
    }

    private fun copyBounded(input: InputStream, output: OutputStream, limit: Long): Long {
        val buffer = ByteArray(128 * 1024)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) return total
            total += read
            check(total <= limit) { "The GitHub response was larger than expected." }
            output.write(buffer, 0, read)
        }
    }

    companion object {
        private const val REPO = "afzlwtu-2/device-bridge"
        private const val INSTALL_PERMISSION = 410
        private const val INSTALL_APK = 411
        private const val CHECKSUM_LIMIT = 128L * 1024
        private const val MAX_APK_BYTES = 1024L * 1024 * 1024
        private val DOWNLOAD_HOSTS = setOf("api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com")
        private val STABLE_VERSION = Regex("(0|[1-9][0-9]{0,3})\\.(0|[1-9][0-9]{0,2})\\.(0|[1-9][0-9]{0,2})")
        private val CHECKSUM_LINE = Regex("([0-9a-fA-F]{16}) [ *](\\S+)")
    }
}
