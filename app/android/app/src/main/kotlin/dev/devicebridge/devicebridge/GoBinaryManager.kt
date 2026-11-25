package dev.devicebridge.devicebridge

import android.content.Context
import io.flutter.FlutterInjector
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream

/**
 * Resolves, hot-swaps, verifies (XXH64 + version probe), and cleans up superseded
 * Go core binaries on Android so debug builds can swap Go binaries cleanly.
 */
object GoBinaryManager {
    private const val TAG = "DeviceBridge.GoBin"
    private const val PREFS = "devicebridge-gobin"
    private val xxh64Pattern = Regex("^[a-f0-9]{16}$")

    data class Spec(val role: String, val bundledSoName: String, val assetName: String)

    val specs = listOf(
        Spec("cli", "libbridge_cli.so", "assets/bin/android-arm64-libbridge_cli.gzbin"),
        Spec("agent", "libbridge_agent.so", "assets/bin/android-arm64-libbridge_agent.gzbin"),
        Spec("tailnet", "libbridge_tailnet.so", "assets/bin/android-arm64-libbridge_tailnet.gzbin"),
        Spec("wg", "libbridge_wg.so", "assets/bin/android-arm64-libbridge_wg.gzbin"),
        Spec("sync", "libbridge_sync.so", "assets/bin/android-arm64-libbridge_sync.gzbin"),
    )

    private fun specFor(role: String): Spec =
        specs.firstOrNull { it.role == role } ?: error("Unknown Go binary role: $role")

    fun verboseEnabled(context: Context): Boolean =
        context.getSharedPreferences("devicebridge-settings", Context.MODE_PRIVATE)
            .getBoolean("verbose_logging", true)

    fun bundled(context: Context, role: String): File =
        File(context.applicationInfo.nativeLibraryDir, specFor(role).bundledSoName)

    private fun packageStamp(context: Context): Long =
        context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime

    @Synchronized
    fun pendingAssetRoles(context: Context): List<String> {
        val stamp = packageStamp(context)
        return specs.filter { needsAsset(context, it.role, stamp) }.map { it.role }
    }

    private fun deviceAbiTag(context: Context): String {
        val libDirName = File(context.applicationInfo.nativeLibraryDir).name
        if (libDirName.contains("x86_64")) return "x86_64"
        if (libDirName.contains("arm64")) return "arm64"
        val primary = Build.SUPPORTED_ABIS.firstOrNull().orEmpty()
        return when {
            primary.contains("x86_64") -> "x86_64"
            primary.contains("arm64") -> "arm64"
            else -> primary.ifBlank { "arm64" }
        }
    }

    private fun assetNameForDevice(context: Context, spec: Spec): String {
        val abi = deviceAbiTag(context)
        return if (abi == "arm64") spec.assetName else "assets/bin/android-$abi-${spec.bundledSoName.removeSuffix(".so")}.gzbin"
    }

    private fun assetExists(context: Context, assetName: String): Boolean =
        runCatching {
            val assetKey = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(assetName)
            context.assets.open(assetKey).close()
            true
        }.getOrDefault(false)

    private fun needsAsset(context: Context, role: String, stamp: Long): Boolean {
        resolve(context, role)
        val spec = specFor(role)
        val asset = assetNameForDevice(context, spec)
        if (!assetExists(context, asset)) return false
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return prefs.getString("source_$role", null) != "picked-file" &&
            prefs.getLong("asset_checked_$role", 0L) != stamp
    }

    @Synchronized
    fun installAsset(context: Context, role: String, bytes: ByteArray, automatic: Boolean): Map<String, Any?> {
        val stamp = packageStamp(context)
        if (automatic && !needsAsset(context, role, stamp)) return mapOf("skipped" to true)
        val status = installBytes(context, role, bytes, "flutter-asset")
        if (status["activated"] == true || status["unchanged"] == true) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putLong("asset_checked_$role", stamp).apply()
        }
        return status
    }

    @Synchronized
    fun resolve(context: Context, role: String): File {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val activePath = prefs.getString("active_path_$role", null)
        if (!activePath.isNullOrBlank()) {
            val f = File(activePath)
            if (f.exists() && f.isFile && f.canExecute()) {
                return f
            }
            prefs.edit().remove("active_path_$role").remove("source_$role").apply()
        }
        return bundled(context, role)
    }

    @Synchronized
    fun installBytes(context: Context, role: String, rawOrGzipBytes: ByteArray, sourceTag: String): Map<String, Any?> {
        val spec = specFor(role)
        val hotDir = File(context.filesDir, "devicebridge/hotbin").apply { mkdirs() }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val payload = maybeGunzip(rawOrGzipBytes)
        if (!looksLikeElf(payload)) {
            error("Selected file is not a valid Android ELF binary for ${spec.role}")
        }
        val gen = System.currentTimeMillis()
        val staged = File(hotDir, "${role}_$gen.bin.tmp")
        val target = File(hotDir, "${role}_$gen.bin")
        val prevPath = prefs.getString("active_path_$role", null)
        try {
            FileOutputStream(staged).use { it.write(payload) }
            staged.setReadable(true, true)
            staged.setExecutable(true, true)
            if (!staged.renameTo(target)) {
                staged.copyTo(target, overwrite = true)
                staged.delete()
                target.setReadable(true, true)
                target.setExecutable(true, true)
            }
            val newHash = computeXxh64(context, target)
            check(xxh64Pattern.matches(newHash)) { "Could not verify the ${spec.role} binary with XXH64" }
            if (!prevPath.isNullOrBlank()) {
                val prevFile = File(prevPath)
                if (prevFile.exists()) {
                    val prevHash = prefs.getString("xxh64_$role", "")
                    if (prevHash == newHash && newHash.isNotEmpty()) {
                        target.delete()
                        prefs.edit().putString("source_$role", sourceTag)
                            .remove("last_error_$role").apply()
                        return statusFor(context, role) + mapOf("unchanged" to true)
                    }
                }
            }
            val probe = probeExecutable(role, target)
            if (probe["ok"] != true) {
                val errMsg = (probe["error"] as? String).orEmpty().ifBlank {
                    "Android SELinux/W^X prevented direct execution from app_data_file; keeping bundled ${spec.bundledSoName}"
                }
                target.delete()
                prefs.edit()
                    .putString("last_error_$role", errMsg)
                    .apply()
                if (verboseEnabled(context)) {
                    Log.w(TAG, "Hot-swap rejected for $role ($sourceTag): $errMsg")
                }
                return statusFor(context, role) + mapOf(
                    "activated" to false,
                    "error" to errMsg,
                )
            }

            prefs.edit()
                .putString("active_path_$role", target.absolutePath)
                .putString("source_$role", sourceTag)
                .putString("xxh64_$role", newHash)
                .putString("version_$role", (probe["version"] as? String).orEmpty())
                .putString("go_${role}", (probe["go"] as? String).orEmpty())
                .putLong("updated_at_$role", gen)
                .remove("last_error_$role")
                .apply()

            // Remove older superseded hot-swap binaries for this role, keeping prevPath
            // briefly so any in-flight ProcessBuilder that resolved prevPath does not hit ENOENT.
            hotDir.listFiles()?.forEach { child ->
                if (child.name.startsWith("${role}_") &&
                    child.absolutePath != target.absolutePath &&
                    child.absolutePath != prevPath) {
                    child.delete()
                }
            }
            if (verboseEnabled(context)) {
                Log.i(TAG, "Hot-swapped $role -> ${target.name} version=${probe["version"]} xxh64=$newHash ($sourceTag)")
            }
            return statusFor(context, role) + mapOf(
                "activated" to true,
                "previous_removed" to !prevPath.isNullOrBlank(),
            )
        } catch (e: Exception) {
            staged.delete()
            target.delete()
            val msg = e.message ?: "Hot-swap failed"
            prefs.edit().putString("last_error_$role", msg).apply()
            throw e
        }
    }

    fun installStream(context: Context, role: String, input: InputStream, sourceTag: String): Map<String, Any?> {
        val bytes = input.use { it.readBytes() }
        return installBytes(context, role, bytes, sourceTag)
    }

    @Synchronized
    fun revert(context: Context, role: String? = null): List<Map<String, Any?>> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val hotDir = File(context.filesDir, "devicebridge/hotbin")
        val targetRoles = if (role != null) listOf(role) else specs.map { it.role }
        val stamp = packageStamp(context)
        val ed = prefs.edit()
        for (r in targetRoles) {
            ed.putLong("asset_checked_$r", stamp)
                .remove("active_path_$r")
                .remove("source_$r")
                .remove("xxh64_$r")
                .remove("version_$r")
                .remove("go_$r")
                .remove("updated_at_$r")
                .remove("last_error_$r")
            hotDir.listFiles()?.forEach { child ->
                if (child.name.startsWith("${r}_")) child.delete()
            }
        }
        ed.apply()
        return allStatuses(context)
    }

    fun allStatuses(context: Context): List<Map<String, Any?>> =
        specs.map { statusFor(context, it.role) }

    fun statusSummary(context: Context): Map<String, Any?> {
        val list = allStatuses(context)
        val cli = list.firstOrNull { it["role"] == "cli" } ?: emptyMap()
        val hotCount = list.count { it["available"] == true && it["source"] != "bundled" }
        return mapOf(
            "version" to (cli["version"] ?: "unknown"),
            "go" to (cli["go"] ?: ""),
            "arch" to (cli["arch"] ?: ""),
            "hot_count" to hotCount,
            "libraries" to list,
        )
    }

    fun statusFor(context: Context, role: String): Map<String, Any?> {
        val spec = specFor(role)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val active = resolve(context, role)
        val bundledFile = bundled(context, role)
        val isHot = active.absolutePath != bundledFile.absolutePath
        val exists = active.exists() && active.isFile
        val executable = exists && active.canExecute()
        var version = if (isHot) prefs.getString("version_$role", "").orEmpty() else ""
        var goVer = if (isHot) prefs.getString("go_$role", "").orEmpty() else ""
        var arch = ""
        if (executable && (version.isEmpty() || !isHot)) {
            val probe = probeExecutable(role, active)
            if (probe["ok"] == true) {
                version = (probe["version"] as? String).orEmpty()
                goVer = (probe["go"] as? String).orEmpty()
                arch = (probe["arch"] as? String).orEmpty()
            }
        }
        val xxh64 = if (exists) computeXxh64(context, active) else ""
        return mapOf(
            "role" to role,
            "bundled_name" to spec.bundledSoName,
            "asset_name" to spec.assetName,
            "path" to active.absolutePath,
            "source" to if (isHot) (prefs.getString("source_$role", "hot-swap") ?: "hot-swap") else "bundled",
            "available" to executable,
            "size_bytes" to if (exists) active.length() else 0L,
            "version" to version.ifBlank { if (executable) "loaded" else "missing" },
            "go" to goVer,
            "arch" to arch.ifBlank { "android/${deviceAbiTag(context)}" },
            "xxh64" to xxh64,
            "last_error" to (prefs.getString("last_error_$role", "") ?: ""),
        )
    }

    private fun maybeGunzip(bytes: ByteArray): ByteArray {
        if (bytes.size >= 2 && bytes[0] == 0x1f.toByte() && bytes[1] == 0x8b.toByte()) {
            return GZIPInputStream(ByteArrayInputStream(bytes)).use { it.readBytes() }
        }
        return bytes
    }

    private fun looksLikeElf(bytes: ByteArray): Boolean =
        bytes.size >= 64 &&
            bytes[0] == 0x7f.toByte() &&
            bytes[1] == 'E'.code.toByte() &&
            bytes[2] == 'L'.code.toByte() &&
            bytes[3] == 'F'.code.toByte()

    private fun computeXxh64(context: Context, file: File): String {
        val helper = bundled(context, "cli").takeIf { it.exists() && it.canExecute() }
            ?: file.takeIf { file.name.contains("cli") && it.canExecute() }
            ?: return ""
        return try {
            val stateDir = File(context.filesDir, "devicebridge").apply { mkdirs() }
            val (exit, out) = runProbe(listOf(helper.absolutePath, "--state", stateDir.absolutePath, "checksum", file.absolutePath))
            if (exit != 0) return ""
            JSONObject(out).optString("xxh64", "")
        } catch (_: Exception) {
            ""
        }
    }

    private fun runProbe(args: List<String>): Pair<Int, String> {
        val process = ProcessBuilder(args).redirectErrorStream(true).start()
        try {
            process.outputStream.close()
            check(process.waitFor(3, TimeUnit.SECONDS)) { "Binary probe timed out" }
            // Probe output is deliberately small. Read only ready bytes after
            // exit so an inherited stdout pipe cannot hold Settings open.
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(1024)
            val input = process.inputStream
            while (output.size() < 16384) {
                val ready = minOf(input.available(), buffer.size, 16384 - output.size())
                if (ready == 0) break
                val n = input.read(buffer, 0, ready)
                if (n <= 0) break
                output.write(buffer, 0, n)
            }
            return process.exitValue() to output.toString(Charsets.UTF_8.name()).trim()
        } finally {
            if (process.isAlive) process.destroyForcibly()
            process.inputStream.close()
        }
    }

    private fun probeExecutable(role: String, binary: File): Map<String, Any?> {
        val args = when (role) {
            "cli" -> listOf(binary.absolutePath, "version")
            "agent" -> listOf(binary.absolutePath, "--version")
            "sync" -> listOf(binary.absolutePath, "--version")
            else -> {
                // tailnet / wg binaries don't yet implement --version; check ELF + --help exits quickly without crashing
                listOf(binary.absolutePath, "--help")
            }
        }
        return try {
            val (exit, out) = runProbe(args)
            if (role == "sync") {
                val version = Regex("^syncthing (v[0-9]+\\.[0-9]+\\.[^ ]+)").find(out)?.groupValues?.get(1)
                if (exit != 0 || version == null) {
                    mapOf("ok" to false, "error" to out.ifBlank { "Invalid Syncthing engine" })
                } else {
                    mapOf("ok" to true, "version" to version, "go" to "", "arch" to "android/arm64")
                }
            } else if (role == "cli" || role == "agent") {
                if (exit != 0) {
                    return mapOf("ok" to false, "error" to out.ifBlank { "Exit $exit" })
                }
                val json = JSONObject(out)
                check(json.optString("name") == "bridge-$role" && json.optString("version").isNotBlank()) {
                    "The binary did not identify itself as bridge-$role"
                }
                mapOf(
                    "ok" to true,
                    "version" to json.optString("version"),
                    "go" to json.optString("go", ""),
                    "arch" to "${json.optString("os", "android")}/${json.optString("arch", "arm64")}",
                )
            } else {
                val signature = if (role == "wg") "-backend" else "app node hostname"
                check((exit == 0 || exit == 2) && out.contains("-state") && out.contains(signature)) {
                    "The binary did not identify itself as the $role sidecar"
                }
                mapOf("ok" to true, "version" to "legacy sidecar", "go" to "", "arch" to "android/arm64")
            }
        } catch (e: Exception) {
            mapOf("ok" to false, "error" to (e.message ?: "exec probe failed"))
        }
    }
}
