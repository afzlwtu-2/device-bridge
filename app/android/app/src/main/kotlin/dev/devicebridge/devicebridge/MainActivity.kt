package dev.devicebridge.devicebridge

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.media.ToneGenerator
import android.net.TrafficStats
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Process as OsProcess
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.DocumentsContract
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.WindowManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newCachedThreadPool()
    private val resourceUsage = ResourceUsage()
    private var saveResult: MethodChannel.Result? = null
    private var saveSource: File? = null
    private var treeResult: MethodChannel.Result? = null
    private var confResult: MethodChannel.Result? = null
    private var sshKeyResult: MethodChannel.Result? = null
    private var goBinResult: MethodChannel.Result? = null
    private var goBinRole: String = "cli"
    private var sharePickResult: MethodChannel.Result? = null
    @Volatile private var wifiPermLatch: java.util.concurrent.CountDownLatch? = null
    @Volatile private var wifiPermGranted: Boolean = false
    private lateinit var termuxControl: TermuxControl
    private lateinit var documentsGateway: DocumentsGateway
    private lateinit var directLink: DirectLinkController
    private lateinit var deviceSettings: DeviceSettings
    private lateinit var lan: LanCoordinator
    private lateinit var tailnet: TailnetCoordinator
    private val tailnetScreenChanged: () -> Unit = {
        networkSink?.success(mapOf("tailnet_network_changed" to true))
    }
    private lateinit var wireguard: WireguardCoordinator
    private var networkSink: EventChannel.EventSink? = null
    private var networkStatus: Map<String, Any?>? = null
    private var usbStateReceiver: BroadcastReceiver? = null
    private var transferSink: EventChannel.EventSink? = null
    private var pendingTransfers = 0
    private var sharedDraftSink: EventChannel.EventSink? = null
    private var sharedDraft: Map<String, Any?>? = null
    private var sharedDraftVersion = 0
    private val shareFiles by lazy { ShareFiles(applicationContext) }
    private var guestTerminalSink: EventChannel.EventSink? = null
    private val guestTerminal by lazy { GuestTerminal(this) { guestTerminalSink?.success(it) } }
    private var localTerminalSink: EventChannel.EventSink? = null
    private val termuxBackup by lazy { TermuxBackup(this, worker) }
    private val localTerminal by lazy {
        LocalTerminal(this, { ::deviceSettings.isInitialized && deviceSettings.detachedTerminalEnabled() }) {
            localTerminalSink?.success(it)
        }
    }
    private var bellSoundPool: SoundPool? = null
    private var bellSoundId: Int = 0
    @Volatile private var bellSoundLoaded: Boolean = false
    private var bellToneGenerator: ToneGenerator? = null
    private var lastBellAtMs: Long = 0L
    @Volatile private var prevCpuTotal: Long = 0L
    @Volatile private var prevCpuIdle: Long = 0L
    private val statsLock = Any()
    private var statsRootProc: Process? = null
    private var statsRootIn: BufferedWriter? = null
    private var statsRootOut: BufferedReader? = null
    private var statsShellMode: String = ""
    private var statsCpuReadable: Boolean = false
    private var statsGpuKind: String = ""
    private var statsGpuPrimaryPath: String = ""
    private var statsGpuSecondaryPath: String = ""
    private var statsGpuMaxKhz: Long = 0L
    private var cancelShareStaging: java.util.concurrent.atomic.AtomicBoolean? = null
    private val targetPrefs by lazy { getSharedPreferences("devicebridge-targets", Context.MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        super.onCreate(savedInstanceState)
        ensureBellSoundPool()
        receiveShareIntent(intent)
    }

    private fun ensureBellSoundPool() {
        if (bellSoundPool != null) return
        try {
            val pool = SoundPool.Builder()
                .setMaxStreams(2)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .build()
                )
                .build()
            pool.setOnLoadCompleteListener { _, sampleId, status ->
                if (status == 0 && sampleId == bellSoundId) {
                    bellSoundLoaded = true
                }
            }
            bellSoundPool = pool
            bellSoundId = pool.load(this, R.raw.bell, 1)
        } catch (_: Exception) {}
    }

    private fun vibrateOneShot(durationMs: Long, amplitude: Int) {
        if (durationMs <= 0L) return
        try {
            val vib: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            if (vib == null || !vib.hasVibrator()) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val amp = if (vib.hasAmplitudeControl()) amplitude.coerceIn(1, 255) else VibrationEffect.DEFAULT_AMPLITUDE
                vib.vibrate(VibrationEffect.createOneShot(durationMs.coerceIn(1L, 200L), amp))
            } else {
                @Suppress("DEPRECATION")
                vib.vibrate(durationMs.coerceIn(1L, 200L))
            }
        } catch (_: Exception) {}
    }

    private fun triggerTerminalBell(mode: String) {
        if (mode == "ignore") return
        val now = android.os.SystemClock.uptimeMillis()
        if (now - lastBellAtMs < 65L) return
        lastBellAtMs = now
        if (mode == "beep" || mode == "beep_vibrate") {
            ensureBellSoundPool()
            var played = false
            val pool = bellSoundPool
            if (pool != null && bellSoundLoaded && bellSoundId != 0) {
                played = pool.play(bellSoundId, 1f, 1f, 1, 0, 1f) != 0
            }
            if (!played) {
                try {
                    val tg = bellToneGenerator ?: ToneGenerator(AudioManager.STREAM_NOTIFICATION, 85).also {
                        bellToneGenerator = it
                    }
                    tg.startTone(ToneGenerator.TONE_PROP_BEEP, 120)
                } catch (_: Exception) {}
            }
        }
        if (mode == "vibrate" || mode == "beep_vibrate") {
            vibrateOneShot(50L, 190)
        }
    }

    private fun triggerTerminalKeyFeedback(
        key: String,
        haptic: Boolean,
        sound: Boolean,
        isSwipeSlot: Boolean,
        durationMs: Int
    ) {
        if (haptic) {
            try {
                val constant = if (isSwipeSlot && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    HapticFeedbackConstants.CLOCK_TICK
                } else {
                    HapticFeedbackConstants.KEYBOARD_TAP
                }
                @Suppress("DEPRECATION")
                window?.decorView?.performHapticFeedback(
                    constant,
                    HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING
                )
            } catch (_: Exception) {}
            if (durationMs > 0) {
                val dur = if (isSwipeSlot) (durationMs * 3 / 4).coerceAtLeast(8) else durationMs
                val amp = if (isSwipeSlot) 145 else 210
                vibrateOneShot(dur.toLong(), amp)
            }
        }
        if (sound && !isSwipeSlot) {
            try {
                val audio = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                val effect = when (key) {
                    "backspace", "delete" -> AudioManager.FX_KEYPRESS_DELETE
                    "enter", "action" -> AudioManager.FX_KEYPRESS_RETURN
                    "space" -> AudioManager.FX_KEYPRESS_SPACEBAR
                    else -> AudioManager.FX_KEYPRESS_STANDARD
                }
                audio?.playSoundEffect(effect, -1f)
            } catch (_: Exception) {}
        }
    }

    private fun parseCpuLine(line: String): Pair<Long, Long>? {
        val parts = line.trim().split(Regex("\\s+"))
        if (parts.size < 5 || parts[0] != "cpu") return null
        var total = 0L
        for (i in 1 until minOf(parts.size, 9)) {
            total += parts[i].toLongOrNull() ?: 0L
        }
        val idle = (parts.getOrNull(4)?.toLongOrNull() ?: 0L) +
            (parts.getOrNull(5)?.toLongOrNull() ?: 0L)
        return total to idle
    }

    private fun closeStatsRootSessionLocked() {
        try { statsRootIn?.close() } catch (_: Exception) {}
        try { statsRootOut?.close() } catch (_: Exception) {}
        try { statsRootProc?.destroy() } catch (_: Exception) {}
        statsRootIn = null
        statsRootOut = null
        statsRootProc = null
        statsShellMode = ""
        statsCpuReadable = false
        statsGpuKind = ""
        statsGpuPrimaryPath = ""
        statsGpuSecondaryPath = ""
        statsGpuMaxKhz = 0L
        prevCpuTotal = 0L
        prevCpuIdle = 0L
    }

    private fun closeStatsRootSession() {
        synchronized(statsLock) {
            closeStatsRootSessionLocked()
        }
    }

    private fun startStatsShellProcess(mode: String): Process? = when (mode) {
        "root" -> ProcessBuilder("su").redirectErrorStream(true).start()
        "shizuku" -> {
            val method = Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java
            ).apply { isAccessible = true }
            method.invoke(null, arrayOf("sh"), null, null) as Process
        }
        else -> null
    }

    private fun ensureStatsShellLocked(desiredMode: String): Boolean {
        val alive = statsRootProc?.let {
            try {
                it.exitValue()
                false
            } catch (_: IllegalThreadStateException) {
                true
            }
        } == true
        if (alive && statsShellMode == desiredMode && statsRootIn != null && statsRootOut != null) {
            return true
        }
        closeStatsRootSessionLocked()
        return try {
            val proc = startStatsShellProcess(desiredMode) ?: return false
            val writer = BufferedWriter(OutputStreamWriter(proc.outputStream))
            val reader = BufferedReader(InputStreamReader(proc.inputStream))
            val initCmd =
                "id -u; " +
                    "if [ -r /proc/stat ]; then echo '@@CPU:ok'; fi; " +
                    "if [ -r /sys/kernel/ged/hal/gpu_utilization ]; then " +
                    "echo '@@GPU:ged:/sys/kernel/ged/hal/gpu_utilization:/proc/gpufreqv2/gpufreq_status'; " +
                    "if [ -r /proc/gpufreqv2/gpu_working_opp_table ] && IFS= read -r opp0 < /proc/gpufreqv2/gpu_working_opp_table; then " +
                    "echo \"@@MAXOPP:\$opp0\"; fi; " +
                    "elif [ -r /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage ]; then " +
                    "echo '@@GPU:kgsl:/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage:'; " +
                    "elif [ -r /sys/kernel/gpu/gpu_busy ]; then " +
                    "echo '@@GPU:kgsl:/sys/kernel/gpu/gpu_busy:'; " +
                    "elif [ -r /sys/module/ged/parameters/gpu_loading ]; then " +
                    "echo '@@GPU:kgsl:/sys/module/ged/parameters/gpu_loading:'; " +
                    "else for f in /sys/class/devfreq/*mali*/cur_freq; do " +
                    "[ -r \"\$f\" ] && echo \"@@GPU:freq:\$f:\${f%cur_freq}max_freq\" && break; done; fi; " +
                    "echo '@@INIT_END'\n"
            writer.write(initCmd)
            writer.flush()
            var uidSeen = ""
            var cpuOk = false
            while (true) {
                val line = reader.readLine()?.trim() ?: break
                if (line == "@@INIT_END") break
                if (uidSeen.isEmpty() && line.toIntOrNull() != null) uidSeen = line
                if (line == "@@CPU:ok") cpuOk = true
                if (line.startsWith("@@GPU:")) {
                    val parts = line.removePrefix("@@GPU:").split(":", limit = 3)
                    statsGpuKind = parts.getOrElse(0) { "" }
                    statsGpuPrimaryPath = parts.getOrElse(1) { "" }
                    statsGpuSecondaryPath = parts.getOrElse(2) { "" }
                }
                if (line.startsWith("@@MAXOPP:")) {
                    val freqStr = line.substringAfter("freq:").trim().substringBefore(",").trim()
                    statsGpuMaxKhz = freqStr.toLongOrNull() ?: 0L
                }
            }
            val valid = when (desiredMode) {
                "root" -> uidSeen == "0"
                "shizuku" -> uidSeen.isNotEmpty()
                else -> false
            }
            if (!valid) {
                try { proc.destroy() } catch (_: Exception) {}
                closeStatsRootSessionLocked()
                return false
            }
            statsShellMode = desiredMode
            statsCpuReadable = cpuOk
            statsRootProc = proc
            statsRootIn = writer
            statsRootOut = reader
            true
        } catch (_: Exception) {
            closeStatsRootSessionLocked()
            false
        }
    }

    private fun queryStatsShellLocked(cmd: String): List<String>? {
        val writer = statsRootIn ?: return null
        val reader = statsRootOut ?: return null
        return try {
            writer.write("$cmd\necho '@@STAT_END'\n")
            writer.flush()
            val out = ArrayList<String>(8)
            while (true) {
                val line = reader.readLine() ?: throw java.io.EOFException("su session closed")
                val trimmed = line.trim()
                if (trimmed == "@@STAT_END") break
                if (trimmed.isNotEmpty()) out.add(trimmed)
            }
            out
        } catch (_: Exception) {
            closeStatsRootSessionLocked()
            null
        }
    }

    private fun sampleRootSystemStats(
        needCpu: Boolean = true,
        needRam: Boolean = true,
        needGpu: Boolean = true
    ): Map<String, Any> {
        return try {
            var ramPercent = 0
            var ramUsedGb = 0.0
            var ramTotalGb = 0.0
            if (needRam) {
                val am = getSystemService(Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
                if (am != null) {
                    val mi = android.app.ActivityManager.MemoryInfo()
                    am.getMemoryInfo(mi)
                    if (mi.totalMem > 0L) {
                        val usedBytes = (mi.totalMem - mi.availMem).coerceAtLeast(0L)
                        ramPercent = ((usedBytes * 100L) / mi.totalMem).toInt().coerceIn(0, 100)
                        ramUsedGb = usedBytes.toDouble() / (1024.0 * 1024.0 * 1024.0)
                        ramTotalGb = mi.totalMem.toDouble() / (1024.0 * 1024.0 * 1024.0)
                    }
                }
            }

            val rootAllowed = deviceSettings.verifyRootEnabled(forceRefresh = false)
            val shizukuAllowed = !rootAllowed && deviceSettings.isShizukuEnabledAndGranted()
            val targetMode = when {
                rootAllowed -> "root"
                shizukuAllowed -> "shizuku"
                else -> ""
            }
            if (targetMode.isEmpty()) {
                synchronized(statsLock) { closeStatsRootSessionLocked() }
                return mapOf(
                    "rooted" to false,
                    "shizuku" to false,
                    "cpu_available" to false,
                    "ram_available" to true,
                    "gpu_available" to false,
                    "cpu_source" to "",
                    "gpu_source" to "",
                    "cpu_percent" to 0,
                    "ram_percent" to ramPercent,
                    "ram_used_gb" to ramUsedGb,
                    "ram_total_gb" to ramTotalGb,
                    "gpu_percent" to 0
                )
            }

            var cpuPercent = 0
            var gpuPercent = 0
            var cpuAvailable = false
            var gpuAvailable = false
            val shellReady = synchronized(statsLock) {
                if (!ensureStatsShellLocked(targetMode)) {
                    return@synchronized false
                }
                cpuAvailable = statsCpuReadable
                gpuAvailable = statsGpuKind.isNotEmpty() && statsGpuPrimaryPath.isNotEmpty()
                val wantCpu = needCpu && cpuAvailable
                val wantGpu = needGpu && gpuAvailable
                if (wantCpu && prevCpuTotal == 0L) {
                    val primeLines = queryStatsShellLocked("IFS= read -r c < /proc/stat 2>/dev/null && printf 'C:%s\\n' \"\$c\"")
                    primeLines?.firstOrNull { it.startsWith("C:") }?.let { line ->
                        parseCpuLine(line.removePrefix("C:"))?.let { (tot, idl) ->
                            prevCpuTotal = tot
                            prevCpuIdle = idl
                        }
                    }
                    try { Thread.sleep(60) } catch (_: InterruptedException) {}
                }
                if (wantCpu || wantGpu) {
                    val sb = StringBuilder()
                    if (wantCpu) {
                        sb.append("IFS= read -r c < /proc/stat 2>/dev/null && printf 'C:%s\\n' \"\$c\"; ")
                    }
                    if (wantGpu) {
                        when (statsGpuKind) {
                            "ged" -> {
                                sb.append("IFS= read -r g < '").append(statsGpuPrimaryPath).append("' 2>/dev/null && printf 'G:%s\\n' \"\$g\"; ")
                                if (statsGpuSecondaryPath.isNotEmpty()) {
                                    sb.append("if [ -r '").append(statsGpuSecondaryPath).append("' ]; then while IFS= read -r p; do case \"\$p\" in *REALOPP*) printf 'R:%s\\n' \"\$p\";; *Power*State*) printf 'P:%s\\n' \"\$p\"; break;; esac; done < '").append(statsGpuSecondaryPath).append("'; fi; ")
                                }
                            }
                            "kgsl" -> {
                                sb.append("IFS= read -r k < '").append(statsGpuPrimaryPath).append("' 2>/dev/null && printf 'K:%s\\n' \"\$k\"; ")
                            }
                            "freq" -> {
                                sb.append("IFS= read -r f1 < '").append(statsGpuPrimaryPath).append("' 2>/dev/null && printf 'F1:%s\\n' \"\$f1\"; ")
                                if (statsGpuSecondaryPath.isNotEmpty()) {
                                    sb.append("IFS= read -r f2 < '").append(statsGpuSecondaryPath).append("' 2>/dev/null && printf 'F2:%s\\n' \"\$f2\"; ")
                                }
                            }
                        }
                    }
                    val cmd = sb.toString().trim()
                    if (cmd.isNotEmpty()) {
                        val lines = queryStatsShellLocked(cmd) ?: return@synchronized false
                        var gedBusy = -1
                        var gedBlock = 0
                        var gedIdle = -1
                        var gpuPoweredDown = false
                        var fmeterKhz = -1L
                        var kgslPercent = -1
                        var curFreq = 0L
                        var maxFreq = 0L
                        for (l in lines) {
                            when {
                                l.startsWith("C:") -> {
                                    parseCpuLine(l.removePrefix("C:"))?.let { (tot, idl) ->
                                        val pTot = prevCpuTotal
                                        val pIdl = prevCpuIdle
                                        if (pTot > 0L && tot > pTot) {
                                            val dTot = tot - pTot
                                            val dIdl = (idl - pIdl).coerceAtLeast(0L)
                                            cpuPercent = (((dTot - dIdl) * 100L) / dTot).toInt().coerceIn(0, 100)
                                        }
                                        prevCpuTotal = tot
                                        prevCpuIdle = idl
                                    }
                                }
                                l.startsWith("G:") -> {
                                    val parts = l.removePrefix("G:").trim().split(Regex("\\s+"))
                                    val b = parts.getOrNull(0)?.toIntOrNull()
                                    if (b != null) {
                                        gedBusy = b.coerceIn(0, 100)
                                        gedBlock = parts.getOrNull(1)?.toIntOrNull()?.coerceIn(0, 100) ?: 0
                                        gedIdle = parts.getOrNull(2)?.toIntOrNull()?.coerceIn(0, 100) ?: -1
                                    }
                                }
                                l.startsWith("R:") -> {
                                    fmeterKhz = l.substringAfter("FmeterFreq:").trim().substringBefore(",").trim().toLongOrNull() ?: -1L
                                }
                                l.startsWith("P:") -> {
                                    if (l.contains("Active: 0") || l.contains("PowerCount: 0")) {
                                        gpuPoweredDown = true
                                    }
                                }
                                l.startsWith("K:") -> {
                                    val cleaned = l.removePrefix("K:").replace("%", "").trim().split(Regex("\\s+")).firstOrNull()
                                    cleaned?.toIntOrNull()?.let { kgslPercent = it.coerceIn(0, 100) }
                                }
                                l.startsWith("F1:") -> curFreq = l.removePrefix("F1:").trim().toLongOrNull() ?: 0L
                                l.startsWith("F2:") -> maxFreq = l.removePrefix("F2:").trim().toLongOrNull() ?: 0L
                            }
                        }
                        gpuPercent = when {
                            gedBusy >= 0 -> {
                                if (gpuPoweredDown || fmeterKhz == 0L || (gedBusy == 100 && gedBlock == 0 && gedIdle == 0 && fmeterKhz <= 0L)) {
                                    0
                                } else if (statsGpuMaxKhz > 0L && fmeterKhz > 0L) {
                                    ((gedBusy.toLong() * fmeterKhz.coerceAtMost(statsGpuMaxKhz)) / statsGpuMaxKhz).toInt().coerceIn(0, 100)
                                } else {
                                    gedBusy
                                }
                            }
                            kgslPercent >= 0 -> if (gpuPoweredDown && kgslPercent == 100) 0 else kgslPercent
                            maxFreq > 0L && !gpuPoweredDown -> ((curFreq * 100L) / maxFreq).toInt().coerceIn(0, 100)
                            else -> 0
                        }
                    }
                }
                true
            }
            mapOf(
                "rooted" to (shellReady && targetMode == "root"),
                "shizuku" to (shellReady && targetMode == "shizuku"),
                "cpu_available" to (shellReady && cpuAvailable),
                "ram_available" to true,
                "gpu_available" to (shellReady && gpuAvailable),
                "cpu_source" to if (shellReady && cpuAvailable) targetMode else "",
                "gpu_source" to if (shellReady && gpuAvailable) targetMode else "",
                "cpu_percent" to if (shellReady && cpuAvailable) cpuPercent else 0,
                "ram_percent" to ramPercent,
                "ram_used_gb" to ramUsedGb,
                "ram_total_gb" to ramTotalGb,
                "gpu_percent" to if (shellReady && gpuAvailable) gpuPercent else 0
            )
        } catch (_: Exception) {
            mapOf(
                "rooted" to false,
                "shizuku" to false,
                "cpu_available" to false,
                "ram_available" to true,
                "gpu_available" to false
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receiveShareIntent(intent)
    }

    private fun receiveShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val version = ++sharedDraftVersion
        @Suppress("DEPRECATION")
        val stream = try { intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) } catch (_: Exception) { null }
        if (stream != null) {
            intent.removeExtra(Intent.EXTRA_STREAM)
            if (intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0) {
                emitShareDraft(mapOf("error" to "The sharing app did not grant read access."))
                return
            }
            worker.execute {
                val draft = try {
                    mapOf("file" to shareFiles.describe(stream))
                } catch (e: Exception) {
                    mapOf("error" to (e.message ?: "Cannot read the shared file."))
                }
                runOnUiThread { if (version == sharedDraftVersion) emitShareDraft(draft) }
            }
            return
        }
        if (intent.type != "text/plain") return
        val text = try {
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        } catch (_: Exception) {
            null
        } ?: return
        intent.removeExtra(Intent.EXTRA_TEXT)
        emitShareDraft(if (text.length <= 4096 && text.toByteArray(Charsets.UTF_8).size <= 4096) {
            mapOf("text" to text)
        } else {
            mapOf("error" to "Shared text exceeds the 4 KiB limit.")
        })
    }

    private fun emitShareDraft(draft: Map<String, Any?>) {
        sharedDraft = draft
        sharedDraftSink?.success(true)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 405) {
            wifiPermGranted = grantResults.isNotEmpty() && grantResults.any { it == PackageManager.PERMISSION_GRANTED }
            wifiPermLatch?.countDown()
            return
        }
        if (::termuxControl.isInitialized) termuxControl.permissionResult(requestCode)
    }

    private fun hasWifiDirectPermissions(): Boolean {
        val fine = checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            applicationInfo.targetSdkVersion >= Build.VERSION_CODES.TIRAMISU) {
            val nearby = checkSelfPermission(android.Manifest.permission.NEARBY_WIFI_DEVICES) == PackageManager.PERMISSION_GRANTED
            return nearby && fine
        }
        return fine
    }

    private fun requestWifiDirectPermissionsSync(): Boolean {
        if (hasWifiDirectPermissions()) return true
        val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            applicationInfo.targetSdkVersion >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(android.Manifest.permission.NEARBY_WIFI_DEVICES, android.Manifest.permission.ACCESS_FINE_LOCATION)
        } else {
            arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val latch = java.util.concurrent.CountDownLatch(1)
        wifiPermGranted = false
        wifiPermLatch = latch
        runOnUiThread { requestPermissions(perms, 405) }
        latch.await(30, java.util.concurrent.TimeUnit.SECONDS)
        wifiPermLatch = null
        return hasWifiDirectPermissions() || wifiPermGranted
    }

    override fun onResume() {
        super.onResume()
        applyAwakeSetting()
        if (::lan.isInitialized) lan.visible(true)
        if (::tailnet.isInitialized) {
            tailnet.visible(true)
            AndroidTailnet.syncProxy(this, tailnet, deviceSettings.tsnetConfig())
        }
        if (::wireguard.isInitialized) wireguard.visible(true)
    }

    override fun onPause() {
        window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        guestTerminal.stop()
        super.onPause()
    }

    override fun onStop() {
        if (::lan.isInitialized) lan.visible(false)
        if (::tailnet.isInitialized) tailnet.visible(false)
        if (::wireguard.isInitialized) wireguard.visible(false)
        super.onStop()
    }

    private fun applyAwakeSetting() {
        val enabled = getSharedPreferences("devicebridge-settings", Context.MODE_PRIVATE).getBoolean("keep_awake", false)
        if (enabled && hasWindowFocus()) window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        applyAwakeSetting()
    }

    override fun onDestroy() {
        closeStatsRootSession()
        guestTerminal.close()
        localTerminal.close()
        try { bellSoundPool?.release() } catch (_: Exception) {}
        bellSoundPool = null
        bellSoundId = 0
        bellSoundLoaded = false
        try { bellToneGenerator?.release() } catch (_: Exception) {}
        bellToneGenerator = null
        if (::tailnet.isInitialized && AndroidTailnet.screenChanged === tailnetScreenChanged) {
            AndroidTailnet.screenChanged = null
            tailnet.detachScreen()
        }
        if (::termuxControl.isInitialized) termuxControl.close()
        if (::documentsGateway.isInitialized) documentsGateway.close()
        if (::directLink.isInitialized) directLink.close()
        if (::deviceSettings.isInitialized) deviceSettings.close()
        try { usbStateReceiver?.let { unregisterReceiver(it) } } catch (_: Exception) {}
        usbStateReceiver = null
        super.onDestroy()
    }

    private fun isTermuxInstalled(): Boolean = try {
        packageManager.getPackageInfo("com.termux", 0); true
    } catch (_: PackageManager.NameNotFoundException) { false }

    // Reopen the completed destination so verification covers bytes stored by
    // the Android document provider after writing the copy.
    private fun checksum(input: java.io.InputStream): String {
        val binary = GoBinaryManager.resolve(applicationContext, "cli")
        val child = ProcessBuilder(binary.path, "--state", File(filesDir, "devicebridge").path, "checksum", "-").start()
        try {
            input.use { source -> child.outputStream.use { source.copyTo(it) } }
            val output = child.inputStream.bufferedReader().use { it.readText() }
            val error = child.errorStream.bufferedReader().use { it.readText() }
            check(child.waitFor() == 0) { "XXH64 verification failed: $error" }
            return org.json.JSONObject(output).getString("xxh64")
        } finally { child.destroy() }
    }

    private fun copyVerifiedFile(source: File, doc: Uri) {
        contentResolver.openOutputStream(doc, "w")!!.use { output -> source.inputStream().use { it.copyTo(output) } }
        val expected = checksum(source.inputStream())
        val actual = checksum(contentResolver.openInputStream(doc) ?: error("Cannot reread completed destination"))
        check(actual == expected) { "Destination XXH64 mismatch; verified private download preserved" }
    }

    private fun copyFileOrDirToDocument(source: File, parentDocUri: Uri) {
        if (!source.isDirectory) {
            val doc = DocumentsContract.createDocument(contentResolver, parentDocUri, "application/octet-stream", source.name)
                ?: error("Cannot create destination file")
            copyVerifiedFile(source, doc)
            return
        }
        val destName = source.name
        val dest = DocumentsContract.createDocument(contentResolver, parentDocUri, DocumentsContract.Document.MIME_TYPE_DIR, destName)
            ?: DocumentsContract.createDocument(contentResolver, parentDocUri, DocumentsContract.Document.MIME_TYPE_DIR, destName + "-" + UUID.randomUUID().toString().take(8))
            ?: error("Cannot create destination folder")
        fun copy(dir: File, target: Uri) {
            for (child in dir.listFiles() ?: error("Cannot enumerate verified download")) {
                check(child.canonicalPath.startsWith(source.canonicalPath + File.separator)) { "Unsafe download entry" }
                val doc = DocumentsContract.createDocument(
                    contentResolver,
                    target,
                    if (child.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream",
                    child.name
                ) ?: error("Cannot create document")
                if (child.isDirectory) copy(child, doc) else copyVerifiedFile(child, doc)
            }
        }
        copy(source, dest)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        deviceSettings = DeviceSettings(applicationContext) { action -> runOnUiThread { action() } }
        tailnet = AndroidTailnet.coordinator(applicationContext)
        AndroidTailnet.screenChanged = tailnetScreenChanged
        tailnet.syncPrefs(deviceSettings.tsnetConfig())
        wireguard = WireguardCoordinator(applicationContext)
        termuxControl = TermuxControl(this)
        documentsGateway = DocumentsGateway(this)
        lateinit var lanRef: LanCoordinator
        directLink = DirectLinkController(
            applicationContext,
            startDirectAgent = { iface, cidr, port -> lanRef.startDirectListener(iface, cidr, port) },
            stopDirectAgent = { lanRef.stopDirectListener(); lanRef.restorePreviousPolicy() },
            ensureWifiPermissions = ::requestWifiDirectPermissionsSync
        )
        CoreRuntime.directNetworkProvider = { directLink.joinedNetworkBinding() }
        lan = LanCoordinator(
            applicationContext,
            { documentsGateway.environment() + directLink.environment() + mapOf("DEVICEBRIDGE_SYNCTHING_BINARY" to GoBinaryManager.resolve(applicationContext, "sync").absolutePath, "TMPDIR" to cacheDir.absolutePath) },
            { tailnet.enabled() || wireguard.enabled() }
        ) { value ->
            runOnUiThread {
                networkStatus = value
                networkSink?.success(value)
            }
            @Suppress("UNCHECKED_CAST")
            val network = value["network"] as? Map<String, Any?>
            val netIface = network?.get("interface") as? String ?: ""
            val netKind = network?.get("kind") as? String ?: ""
            val isDirectSub = netKind == "hotspot" || netKind == "wifi_direct" ||
                netIface.startsWith("ap") || netIface.startsWith("swlan") || netIface.startsWith("p2p")
            val overlayNet = if (isDirectSub) {
                lanRef.networks().firstOrNull { it["kind"] == "wifi" } ?: network
            } else {
                network
            }
            val extraDirect = if (isDirectSub) {
                network
            } else {
                lanRef.networks().firstOrNull {
                    val ni = it["interface"] as? String ?: ""
                    val nk = it["kind"] as? String ?: ""
                    nk == "hotspot" || nk == "wifi_direct" ||
                        ni.startsWith("ap") || ni.startsWith("swlan") || ni.startsWith("p2p")
                }
            }
            val receiver = value["endpoint"] as? String ?: "127.0.0.1:8731"
            tailnet.network(overlayNet, receiver, extraDirect)
            wireguard.network(overlayNet, receiver)
            if (deviceSettings.tsnetConfig()["openssh_enabled"] == true) {
                worker.execute {
                    try {
                        val cli = GoBinaryManager.resolve(applicationContext, "cli")
                        if (cli.canExecute()) {
                            val stateDir = File(filesDir, "devicebridge").path
                            val pb = ProcessBuilder(cli.path, "--state", stateDir, "ensure-termux-ssh", "--openssh=true")
                            pb.environment()["DEVICEBRIDGE_APP_PACKAGE"] = packageName
                            pb.environment()["DEVICEBRIDGE_NATIVE_LIB_DIR"] = applicationInfo.nativeLibraryDir
                            pb.start().waitFor(5, java.util.concurrent.TimeUnit.SECONDS)
                        }
                    } catch (_: Exception) {}
                }
            }
        }
        lanRef = lan
        worker.execute {
            try {
                directLink.resumeOrphanedIfPresent()
            } catch (_: Exception) {}
            try {
                val cli = GoBinaryManager.resolve(applicationContext, "cli")
                if (cli.canExecute()) {
                    val stateDir = File(filesDir, "devicebridge").path
                    val openSsh = deviceSettings.tsnetConfig()["openssh_enabled"] == true
                    val pb = ProcessBuilder(cli.path, "--state", stateDir, "ensure-termux-ssh", "--openssh=$openSsh")
                    pb.environment()["DEVICEBRIDGE_APP_PACKAGE"] = packageName
                    pb.environment()["DEVICEBRIDGE_NATIVE_LIB_DIR"] = applicationInfo.nativeLibraryDir
                    pb.start()
                        .waitFor(5, java.util.concurrent.TimeUnit.SECONDS)
                }
            } catch (_: Exception) {}
        }
        EventChannel(engine.dartExecutor.binaryMessenger, "dev.devicebridge/network").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { networkSink = events; networkStatus?.let { events.success(it) } }
            override fun onCancel(arguments: Any?) { networkSink = null }
        })
        if (usbStateReceiver == null) {
            val usbFilter = IntentFilter().apply {
                addAction("android.hardware.usb.action.USB_STATE")
                addAction(Intent.ACTION_POWER_CONNECTED)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
            }
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context?, intent: Intent?) {
                    runOnUiThread { networkSink?.success(mapOf("usb_state_changed" to true)) }
                }
            }
            usbStateReceiver = receiver
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    registerReceiver(receiver, usbFilter, Context.RECEIVER_EXPORTED)
                } else {
                    @Suppress("DEPRECATION")
                    registerReceiver(receiver, usbFilter)
                }
            } catch (_: Exception) {
                usbStateReceiver = null
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, "dev.devicebridge/transfer").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { transferSink = events }
            override fun onCancel(arguments: Any?) { transferSink = null }
        })
        EventChannel(engine.dartExecutor.binaryMessenger, "dev.devicebridge/shared_draft").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sharedDraftSink = events
                if (sharedDraft != null) events.success(true)
            }
            override fun onCancel(arguments: Any?) { sharedDraftSink = null }
        })
        EventChannel(engine.dartExecutor.binaryMessenger, "dev.devicebridge/guest_terminal").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { guestTerminalSink = events }
            override fun onCancel(arguments: Any?) { guestTerminalSink = null; guestTerminal.stop() }
        })
        EventChannel(engine.dartExecutor.binaryMessenger, "dev.devicebridge/local_terminal").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { localTerminalSink = events }
            override fun onCancel(arguments: Any?) { localTerminalSink = null }
        })
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.devicebridge/core").setMethodCallHandler { call, result ->
            when (call.method) {
                "createTermuxBackup" -> termuxBackup.pick(false, localTerminal, result)
                "restoreTermuxBackup" -> termuxBackup.pick(true, localTerminal, result)
                "savedTermuxPackages" -> result.success(termuxBackup.savedPackages())
                "localTerminalStart", "localTerminalWrite" -> {
                    val sessionId = call.argument<String>("session_id") ?: "default"
                    val frame = call.argument<String>("frame")
                    if (termuxBackup.restoring && call.method == "localTerminalStart") {
                        result.error("termux_busy", "Termux Home is being restored.", null)
                    } else if (frame == null) {
                        result.error("invalid_terminal_frame", "A terminal frame is required.", null)
                    } else {
                        val reply: (Exception?) -> Unit = { error ->
                            if (error == null) result.success(null)
                            else result.error("local_terminal_failed", error.message, null)
                        }
                        if (call.method == "localTerminalStart") localTerminal.start(sessionId, frame, reply)
                        else localTerminal.write(sessionId, frame, reply)
                    }
                }
                "localTerminalStop" -> {
                    localTerminal.stop(call.argument<String>("session_id"))
                    result.success(null)
                }
                "detachedLocalTerminals" -> localTerminal.listDetached { result.success(it) }
                "terminalBell" -> {
                    val mode = call.argument<String>("mode") ?: "beep_vibrate"
                    triggerTerminalBell(mode)
                    result.success(null)
                }
                "terminalKeyFeedback" -> {
                    val key = call.argument<String>("key") ?: ""
                    val haptic = call.argument<Boolean>("haptic") ?: true
                    val sound = call.argument<Boolean>("sound") ?: false
                    val isSwipeSlot = call.argument<Boolean>("is_swipe_slot") ?: false
                    val durationMs = call.argument<Int>("duration_ms") ?: 18
                    triggerTerminalKeyFeedback(key, haptic, sound, isSwipeSlot, durationMs)
                    result.success(null)
                }
                "terminalSystemStats" -> {
                    val needCpu = call.argument<Boolean>("need_cpu") ?: true
                    val needRam = call.argument<Boolean>("need_ram") ?: true
                    val needGpu = call.argument<Boolean>("need_gpu") ?: true
                    worker.execute {
                        val stats = sampleRootSystemStats(needCpu, needRam, needGpu)
                        runOnUiThread { result.success(stats) }
                    }
                }
                "guestTerminalStart", "guestTerminalWrite" -> {
                    val frame = call.argument<String>("frame")
                    if (frame == null) {
                        result.error("invalid_terminal_frame", "A terminal frame is required.", null)
                    } else {
                        val reply: (Exception?) -> Unit = { error ->
                            if (error == null) result.success(null)
                            else result.error("guest_terminal_failed", error.message, null)
                        }
                        if (call.method == "guestTerminalStart") {
                            val subcommand = call.argument<String>("subcommand") ?: "guest-terminal"
                            val extraArgs = call.argument<List<String>>("args") ?: emptyList()
                            guestTerminal.start(frame, subcommand, extraArgs, reply)
                        } else {
                            guestTerminal.write(frame, reply)
                        }
                    }
                }
                "guestTerminalStop" -> { guestTerminal.stop(); result.success(null) }
                "takeSharedDraft" -> {
                    val received = sharedDraft
                    sharedDraft = null
                    result.success(received)
                }
                "pickShareFile" -> {
                    if (sharePickResult != null) {
                        result.error("picker_busy", "A file picker is already open.", null)
                    } else {
                        try {
                            sharePickResult = result
                            val folder = call.argument<Boolean>("directory") == true
                            val intent = if (folder) Intent(Intent.ACTION_OPEN_DOCUMENT_TREE) else
                                Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE)
                            startActivityForResult(intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), if (folder) 408 else 407)
                        } catch (e: Exception) {
                            sharePickResult = null
                            result.error("share_picker_failed", e.message, null)
                        }
                    }
                }
                "stageShareFile" -> {
                    val uri = Uri.parse(call.argument<String>("uri") ?: "")
                    val folder = call.argument<Boolean>("directory") == true
                    if (cancelShareStaging != null) {
                        result.error("share_busy", "An item is already being prepared.", null)
                        return@setMethodCallHandler
                    }
                    val cancelled = java.util.concurrent.atomic.AtomicBoolean()
                    cancelShareStaging = cancelled
                    worker.execute {
                        try {
                            val checkActive = { check(!cancelled.get()) { "Transfer cancelled." } }
                            val path = if (folder) shareFiles.stageFolder(uri, checkActive) else shareFiles.stage(uri, checkActive)
                            runOnUiThread {
                                cancelShareStaging = null
                                if (cancelled.get()) {
                                    worker.execute { File(path).parentFile?.deleteRecursively() }
                                    result.error("cancelled", "Transfer cancelled.", null)
                                } else {
                                    result.success(path)
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                cancelShareStaging = null
                                result.error("share_file_failed", e.message, null)
                            }
                        }
                    }
                }
                "localFiles" -> {
                    val operation = call.argument<String>("operation") ?: ""
                    val arguments = call.argument<Map<String, Any?>>("arguments") ?: emptyMap()
                    if (operation == "termux-status") { result.success(termuxControl.status()); return@setMethodCallHandler }
                    if (operation == "termux-permission") { termuxControl.permission(result); return@setMethodCallHandler }
                    if (operation == "termux-run") {
                        termuxControl.run(arguments["program"] as? String ?: "", (arguments["arguments"] as? List<*>)?.map { it as String } ?: emptyList(), result)
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        try {
                            val value = LocalFiles(this, ::checksum).execute(operation, arguments)
                            runOnUiThread { result.success(value) }
                        } catch (e: Exception) { runOnUiThread { result.error("local_files_failed", e.message, null) } }
                    }
                }
                "startupSettings" -> result.success(deviceSettings.startupSettings())
                "appSettings" -> {
                    worker.execute {
                        val snapshot = deviceSettings.read()
                        runOnUiThread { result.success(snapshot) }
                    }
                }
                "updateAppSettings" -> {
                    val args = call.arguments as? Map<String, Any?> ?: emptyMap()
                    deviceSettings.update(args, result)
                    if (args["root_enabled"] == false || args["root_feature_keep_terminal"] == false) {
                        localTerminal.stopDetached()
                    }
                    applyAwakeSetting()
                    if (args.containsKey("agent_enabled")) lan.forceRestart()
                    if (::tailnet.isInitialized) {
                        val config = deviceSettings.tsnetConfig()
                        tailnet.syncPrefs(config)
                        if (args.containsKey("tsnet_socks5_enabled")) {
                            AndroidTailnet.syncProxy(this, tailnet, config)
                        }
                    }
                    if (args.containsKey("tsnet_openssh_enabled")) {
                        val openSsh = deviceSettings.tsnetConfig()["openssh_enabled"] == true
                        worker.execute {
                            try {
                                val cli = GoBinaryManager.resolve(applicationContext, "cli")
                                if (cli.canExecute()) {
                                    val stateDir = File(filesDir, "devicebridge").path
                                    val pb = ProcessBuilder(cli.path, "--state", stateDir, "ensure-termux-ssh", "--openssh=$openSsh")
                                    pb.environment()["DEVICEBRIDGE_APP_PACKAGE"] = packageName
                                    pb.environment()["DEVICEBRIDGE_NATIVE_LIB_DIR"] = applicationInfo.nativeLibraryDir
                                    pb.start()
                                        .waitFor(5, java.util.concurrent.TimeUnit.SECONDS)
                                }
                            } catch (_: Exception) {}
                        }
                    }
                }
                "goBinariesStatus" -> {
                    worker.execute {
                        val st = GoBinaryManager.statusSummary(applicationContext)
                        runOnUiThread { result.success(st) }
                    }
                }
                "pendingGoAssetRoles" -> {
                    worker.execute {
                        try {
                            val roles = GoBinaryManager.pendingAssetRoles(applicationContext)
                            runOnUiThread { result.success(roles) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("go_asset_status_failed", e.message, null) }
                        }
                    }
                }
                "hotSwapGoAsset" -> {
                    val role = call.argument<String>("role") ?: ""
                    val bytes = call.argument<ByteArray>("bytes")
                    val automatic = call.argument<Boolean>("automatic") == true
                    if (role.isBlank() || bytes == null) {
                        result.error("invalid_args", "role and bytes are required", null)
                    } else {
                        worker.execute {
                            try {
                                val res = GoBinaryManager.installAsset(applicationContext, role, bytes, automatic)
                                if (res["activated"] == true) {
                                    when (role) {
                                        "agent" -> if (::lan.isInitialized) runOnUiThread { lan.forceRestart() }
                                        "tailnet" -> if (::tailnet.isInitialized) runOnUiThread { tailnet.forceRestart() }
                                        "wg" -> if (::wireguard.isInitialized) runOnUiThread { wireguard.forceRestart() }
                                    }
                                }
                                runOnUiThread { result.success(res) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("go_swap_failed", e.message, null) }
                            }
                        }
                    }
                }
                "pickGoBinaryFile" -> {
                    if (goBinResult != null) {
                        result.error("busy", "A binary picker is already open", null)
                    } else {
                        goBinRole = call.argument<String>("role") ?: "cli"
                        goBinResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        startActivityForResult(intent, 406)
                    }
                }
                "revertGoBinaries" -> {
                    val role = call.argument<String>("role")
                    worker.execute {
                        val list = GoBinaryManager.revert(applicationContext, role)
                        runOnUiThread {
                            if (::lan.isInitialized && (role == null || role == "agent")) lan.forceRestart()
                            if (::tailnet.isInitialized && (role == null || role == "tailnet")) tailnet.forceRestart()
                            if (::wireguard.isInitialized && (role == null || role == "wg")) wireguard.forceRestart()
                            result.success(GoBinaryManager.statusSummary(applicationContext) + mapOf("libraries" to list))
                        }
                    }
                }
                "configuration" -> {
                    val deviceName = (try {
                        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
                    } catch (_: Exception) {
                        null
                    } ?: "").trim().ifEmpty { (Build.MODEL ?: "").trim().ifEmpty { "Android phone" } }
                    result.success(mapOf(
                        "state" to File(filesDir, "devicebridge").path,
                        "binary" to GoBinaryManager.resolve(applicationContext, "cli").path,
                        "device_name" to deviceName
                    ))
                }
                "refreshExports" -> { lan.refreshExports(); result.success(null) }
                "networks" -> result.success(lan.networks())
                "activateLan" -> { lan.activate(call.argument<Map<String, Any?>>("network")); result.success(null) }
                "approveLan" -> {
                    try { lan.approve(call.argument<Map<String, Any?>>("network") ?: emptyMap()); result.success(null) }
                    catch (e: Exception) { result.error("network_changed", e.message, null) }
                }
                "tailnetEnable" -> {
                    tailnet.enable(call.argument<Boolean>("enabled") == true)
                    AndroidTailnet.syncProxy(this, tailnet, deviceSettings.tsnetConfig())
                    lan.refreshOverlays()
                    result.success(null)
                }
                "wireguardEnable" -> {
                    wireguard.enable(call.argument<Boolean>("enabled") == true)
                    lan.refreshOverlays()
                    result.success(null)
                }
                "pickConfText" -> {
                    if (confResult != null) {
                        result.error("busy", "A config file picker is already open", null)
                    } else {
                        confResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        startActivityForResult(intent, 403)
                    }
                }
                "pickSshKeyText" -> {
                    if (sshKeyResult != null) {
                        result.error("busy", "A key file picker is already open", null)
                    } else {
                        sshKeyResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        startActivityForResult(intent, 404)
                    }
                }
                "openLogin" -> {
                    val value = call.argument<String>("url") ?: ""
                    val uri = Uri.parse(value)
                    if (uri.scheme == "https" && uri.host == "login.tailscale.com") {
                        tailnet.awaitingLogin()
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(null)
                    } else result.error("invalid_login", "Only the official Tailscale login page may be opened", null)
                }
                "platformCapabilities" -> {
                    worker.execute {
                        val allFiles = Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()
                        val caps = directLink.capabilitiesMap().toMutableMap()
                        caps["cellular"] = packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)
                        caps["tailnet_enabled"] = tailnet.enabled()
                        caps["hotspot_sta_concurrent"] = caps["wifi"] == true && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                            getSystemService(android.net.wifi.WifiManager::class.java)?.isStaApConcurrencySupported == true
                        caps["adb_wifi_enabled"] = false // Wireless ADB ignored (equal to Wi-Fi LAN)
                        caps["termux_installed"] = isTermuxInstalled()
                        caps["all_files_access"] = allFiles
                        caps["termux_home_path"] = File(filesDir, "terminal/files/home").apply { mkdirs() }.canonicalPath
                        runOnUiThread { result.success(caps) }
                    }
                }
                "prepareDirectLink" -> {
                    val kind = call.argument<String>("kind") ?: ""
                    val band = call.argument<String>("band") ?: "auto"
                    val ssid = call.argument<String>("ssid") ?: ""
                    val pass = call.argument<String>("passphrase") ?: ""
                    val freqMhz = (call.argument<Number>("frequency_mhz"))?.toInt() ?: 0
                    val channel = (call.argument<Number>("channel"))?.toInt() ?: 0
                    val bwMhz = (call.argument<Number>("bandwidth_mhz"))?.toInt() ?: 0
                    val peerId = call.argument<String>("peer_id").orEmpty()
                    val peerEndpoint = call.argument<String>("peer_endpoint").orEmpty()
                    val peerKind = call.argument<String>("peer_kind").orEmpty()
                    worker.execute {
                        try {
                            val operationId = call.argument<String>("operation_id").orEmpty()
                            if (operationId.isNotEmpty()) {
                                require(kind in setOf("hotspot", "wifi_direct", "wifi_join")) { "Unsupported leased link" }
                                directLink.beginLocalLease(operationId, (call.argument<Number>("lease_seconds"))?.toInt() ?: 120)
                            }
                            val res = directLink.prepare(kind, band, ssid, pass, freqMhz, channel, bwMhz, peerId, peerEndpoint, peerKind)
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("direct_link_failed", e.message, null) }
                        }
                    }
                }
                "commitDirectLink" -> {
                    val operationId = call.argument<String>("operation_id").orEmpty()
                    worker.execute {
                        try { directLink.commitLocalLease(operationId); runOnUiThread { result.success(true) } }
                        catch (e: Exception) { runOnUiThread { result.error("link_commit_failed", e.message, null) } }
                    }
                }
                "stopDirectLink" -> {
                    worker.execute {
                        try {
                            val res = directLink.restore(forget = call.argument<Boolean>("forget") != false)
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("direct_link_stop_failed", e.message, null) }
                        }
                    }
                }
                "activeDirectLink" -> {
                    worker.execute {
                        try {
                            val res = directLink.activeSessionMap() + directLink.localLeaseStatus()
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(mapOf("active" to false, "error" to (e.message ?: ""))) }
                        }
                    }
                }
                "directLinkNeighbors" -> {
                    val iface = call.argument<String>("interface") ?: ""
                    worker.execute {
                        val list = if (iface.isNotBlank()) directLink.neighbors(iface) else emptyList()
                        runOnUiThread { result.success(list) }
                    }
                }
                "linkDetails" -> {
                    val iface = call.argument<String>("interface") ?: ""
                    worker.execute {
                        val info = directLink.linkDetails(iface)
                        runOnUiThread { result.success(info) }
                    }
                }
                "connectionSetup" -> {
                    val kind = call.argument<String>("kind")
                    if (kind == "shizuku" || kind == "termux") {
                        val intent = packageManager.getLaunchIntentForPackage(if (kind == "termux") "com.termux" else "moe.shizuku.privileged.api")
                        if (intent == null) result.error("unavailable", "${if (kind == "termux") "Termux" else "Shizuku"} is not installed", null)
                        else { startActivity(intent); result.success(null) }
                        return@setMethodCallHandler
                    }
                    if (kind == "all_files_access" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))
                        try { startActivity(intent); result.success(null) } catch (e: Exception) { result.error("unavailable", e.message, null) }
                    } else if (kind == "wifi_direct" && !packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)) {
                        result.error("unavailable", "This device does not report Wi-Fi Direct support", null)
                    } else {
                        val action = when (kind) {
                            "hotspot" -> "android.settings.TETHER_SETTINGS"
                            "wifi_direct" -> "android.settings.WIFI_DIRECT_SETTINGS"
                            "adb" -> Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS
                            "cellular" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) Settings.Panel.ACTION_INTERNET_CONNECTIVITY else Settings.ACTION_WIRELESS_SETTINGS
                            else -> Settings.ACTION_WIFI_SETTINGS
                        }
                        var intent = Intent(action)
                        if (intent.resolveActivity(packageManager) == null) intent = Intent(Settings.ACTION_WIFI_SETTINGS)
                        try { startActivity(intent); result.success(null) } catch(e: Exception) { result.error("unavailable", e.message, null) }
                    }
                }
                "pickTargetTree" -> {
                    if (treeResult != null) {
                        result.error("busy", "A folder picker is already open", null)
                    } else {
                        treeResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                        }
                        startActivityForResult(intent, 402)
                    }
                }
                "listTargetTree" -> {
                    val treeUriStr = call.argument<String>("uri")
                    val docId = call.argument<String>("document_id")
                    if (treeUriStr.isNullOrBlank()) {
                        result.error("invalid_uri", "No SAF target tree selected", null)
                    } else {
                        worker.execute {
                            try {
                                val treeUri = requireSafFolder(Uri.parse(treeUriStr))
                                val parentId = if (docId.isNullOrBlank()) DocumentsContract.getTreeDocumentId(treeUri) else docId
                                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
                                val entries = mutableListOf<Map<String, Any?>>()
                                val cols = arrayOf(
                                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                                    DocumentsContract.Document.COLUMN_SIZE,
                                    DocumentsContract.Document.COLUMN_LAST_MODIFIED
                                )
                                contentResolver.query(childrenUri, cols, null, null, null)?.use { c ->
                                    val iId = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                                    val iName = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                                    val iMime = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                                    val iSize = c.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                                    val iMod = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                                    while (c.moveToNext()) {
                                        val name = c.getString(iName) ?: continue
                                        val mime = c.getString(iMime) ?: ""
                                        val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR
                                        entries.add(mapOf(
                                            "name" to name,
                                            "document_id" to c.getString(iId),
                                            "kind" to if (isDir) "directory" else "file",
                                            "size" to if (iSize >= 0 && !c.isNull(iSize)) c.getLong(iSize) else 0L,
                                            "modified_ms" to if (iMod >= 0 && !c.isNull(iMod)) c.getLong(iMod) else 0L
                                        ))
                                    }
                                }
                                entries.sortWith(compareBy<Map<String, Any?>>({ it["kind"] != "directory" }, { (it["name"] as String).lowercase() }))
                                runOnUiThread { result.success(mapOf("root_document_id" to DocumentsContract.getTreeDocumentId(treeUri), "document_id" to parentId, "entries" to entries)) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("target_list_failed", e.message, null) }
                            }
                        }
                    }
                }
                "createTargetFolder" -> {
                    val treeUriStr = call.argument<String>("uri")
                    val docId = call.argument<String>("document_id")
                    val name = call.argument<String>("name")
                    if (treeUriStr.isNullOrBlank() || name.isNullOrBlank()) {
                        result.error("invalid_args", "Folder name and target URI required", null)
                    } else {
                        worker.execute {
                            try {
                                val treeUri = requireSafFolder(Uri.parse(treeUriStr))
                                val parentId = if (docId.isNullOrBlank()) DocumentsContract.getTreeDocumentId(treeUri) else docId
                                val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
                                val created = DocumentsContract.createDocument(contentResolver, parentUri, DocumentsContract.Document.MIME_TYPE_DIR, name)
                                    ?: error("Cannot create folder")
                                runOnUiThread { result.success(DocumentsContract.getDocumentId(created)) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("mkdir_failed", e.message, null) }
                            }
                        }
                    }
                }
                "exportToTargetTree" -> {
                    val sourcePath = call.argument<String>("path") ?: ""
                    val treeUriStr = call.argument<String>("uri") ?: ""
                    val docId = call.argument<String>("document_id")
                    worker.execute {
                        try {
                            val source = File(sourcePath).canonicalFile
                            val downloads = File(filesDir, "devicebridge/downloads").canonicalFile
                            check(source.path.startsWith(downloads.path + File.separator) && source.exists()) { "Only verified app downloads may be exported" }
                            val treeUri = requireSafFolder(Uri.parse(treeUriStr))
                            val parentId = if (docId.isNullOrBlank()) DocumentsContract.getTreeDocumentId(treeUri) else docId
                            val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
                            copyFileOrDirToDocument(source, parentUri)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("export_failed", "Verified private download preserved. ${e.message}", null) }
                        }
                    }
                }
                "execute" -> {
                    val args = call.argument<List<String>>("arguments") ?: emptyList()
                    val input = call.argument<String>("input") ?: ""
                    val transfer = call.argument<Boolean>("transfer") ?: false
                    val pullLan = if (transfer && call.argument<Boolean>("resumablePull") == true) lan::approvedPullLan else null
                    val parallelProbe = !transfer && call.argument<Boolean>("parallelProbe") == true
                    if (args.size < 3 || args[0] != "--state" || args[1] != File(filesDir, "devicebridge").path) {
                        result.error("invalid_arguments", "Core state must remain inside this app", null)
                    } else {
                        if (transfer) {
                            if (pendingTransfers == 0) {
                                try {
                                    startForegroundService(Intent(this, TransferService::class.java))
                                } catch (e: Exception) {
                                    result.error("transfer_service_failed", e.message, null)
                                    return@setMethodCallHandler
                                }
                                tailnet.transferring(true)
                                wireguard.transferring(true)
                            }
                            pendingTransfers++
                        }
                        worker.execute {
                            try {
                                val output = CoreRuntime.execute(
                                    applicationContext, args, input, parallelProbe, pullLan,
                                    if (pullLan != null) tailnet::pullNetwork else null
                                ) { progress ->
                                    runOnUiThread { transferSink?.success(progress) }
                                }
                                runOnUiThread { result.success(output) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("core_failed", e.message, null) }
                            } finally {
                                if (transfer) runOnUiThread {
                                    pendingTransfers--
                                    if (pendingTransfers == 0) {
                                        transferSink?.success(mapOf("transfer_state" to "finished"))
                                        stopService(Intent(this, TransferService::class.java))
                                        tailnet.transferring(false)
                                        wireguard.transferring(false)
                                    }
                                }
                            }
                        }
                    }
                }
                "allowMeteredPull" -> {
                    try {
                        val id = call.argument<String>("id") ?: ""
                        check(CoreRuntime.allowMeteredPull(id)) { "This download is no longer waiting for approval" }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("transfer_approval_failed", e.message, null)
                    }
                }
                "cancel" -> {
                    val staging = cancelShareStaging
                    if (staging != null) staging.set(true) else CoreRuntime.cancel()
                    result.success(null)
                }
                "saveSharedFile" -> {
                    try {
                        check(saveResult == null) { "A document picker is already open" }
                        val name = call.argument<String>("name") ?: ""
                        check(ShareFiles.validName(name)) { "Invalid received file name." }
                        val inbox = File(filesDir, "devicebridge/shared-files")
                        check(inbox.absoluteFile == inbox.canonicalFile) { "The inbox is not a private folder." }
                        val source = File(inbox, name)
                        check(source.absoluteFile == source.canonicalFile && (source.isFile || source.isDirectory)) {
                            "The received item is unavailable."
                        }
                        saveSource = source
                        saveResult = result
                        val destination = if (source.isDirectory) Intent(Intent.ACTION_OPEN_DOCUMENT_TREE) else
                            Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            type = "application/octet-stream"
                            addCategory(Intent.CATEGORY_OPENABLE)
                            putExtra(Intent.EXTRA_TITLE, name)
                        }
                        startActivityForResult(destination, 401)
                    } catch (e: Exception) {
                        if (saveResult === result) { saveResult = null; saveSource = null }
                        result.error("save_failed", e.message, null)
                    }
                }
                "restartAgent" -> {
                    lan.forceRestart()
                    result.success(true)
                }
                "runtimeStatus" -> {
                    val includeResources = call.argument<Boolean>("include_resources") == true
                    worker.execute {
                        try {
                            val snap = buildRuntimeStatus(includeResources)
                            runOnUiThread { result.success(snap) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("runtime_status_failed", e.message, null) }
                        }
                    }
                }
                "trafficConnections" -> {
                    worker.execute {
                        val data = resourceUsage.trafficConnections(filesDir, deviceSettings.rootDiagnosticsEnabled())
                        runOnUiThread { result.success(data) }
                    }
                }
                "proxyClientApps" -> {
                    val serverPort = call.argument<Int>("port") ?: 0
                    val clientPorts = call.argument<List<Int>>("client_ports").orEmpty()
                        .take(64).filter { it in 1..65535 }.toSet()
                    worker.execute {
                        val uids = if (deviceSettings.rootDiagnosticsEnabled()) {
                            resourceUsage.proxyClientUids(serverPort, clientPorts)
                        } else null
                        val apps = uids?.sorted()?.map { uid ->
                            val packages = packageManager.getPackagesForUid(uid)?.sorted().orEmpty()
                            mapOf("uid" to uid, "packages" to packages)
                        }
                        runOnUiThread { result.success(apps) }
                    }
                }
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
        if (requestCode == 409 && termuxBackup.handle(requestCode, resultCode, data)) return
        if (requestCode == 407 || requestCode == 408) {
            val reply = sharePickResult ?: return
            sharePickResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                reply.success(null)
                return
            }
            worker.execute {
                try {
                    val file = if (requestCode == 408) shareFiles.describeFolder(uri) else shareFiles.describe(uri)
                    runOnUiThread { reply.success(file) }
                } catch (e: Exception) {
                    runOnUiThread { reply.error("share_file_failed", e.message, null) }
                }
            }
            return
        }
        if (requestCode == 406) {
            val reply = goBinResult ?: return
            val role = goBinRole
            goBinResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { reply.success(null); return }
            worker.execute {
                try {
                    val res = contentResolver.openInputStream(uri)?.use { stream ->
                        GoBinaryManager.installStream(applicationContext, role, stream, "picked-file")
                    } ?: error("Cannot open selected Go binary file")
                    if (res["activated"] == true) {
                        when (role) {
                            "agent" -> if (::lan.isInitialized) runOnUiThread { lan.forceRestart() }
                            "tailnet" -> if (::tailnet.isInitialized) runOnUiThread { tailnet.forceRestart() }
                            "wg" -> if (::wireguard.isInitialized) runOnUiThread { wireguard.forceRestart() }
                        }
                    }
                    runOnUiThread { reply.success(res) }
                } catch (e: Exception) {
                    runOnUiThread { reply.error("go_swap_failed", e.message, null) }
                }
            }
            return
        }
        if (requestCode == 404) {
            val reply = sshKeyResult ?: return
            sshKeyResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { reply.success(null); return }
            worker.execute {
                try {
                    val bytes = contentResolver.openInputStream(uri)?.use { it.readNBytes(65536) }
                        ?: error("Cannot read selected SSH key file")
                    runOnUiThread { reply.success(String(bytes, Charsets.UTF_8)) }
                } catch (e: Exception) {
                    runOnUiThread { reply.error("ssh_key_read_failed", e.message, null) }
                }
            }
            return
        }
        if (requestCode == 403) {
            val reply = confResult ?: return
            confResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { reply.success(null); return }
            worker.execute {
                try {
                    val bytes = contentResolver.openInputStream(uri)?.use { it.readNBytes(65536) }
                        ?: error("Cannot read selected .conf file")
                    runOnUiThread { reply.success(String(bytes, Charsets.UTF_8)) }
                } catch (e: Exception) {
                    runOnUiThread { reply.error("conf_read_failed", e.message, null) }
                }
            }
            return
        }
        if (requestCode == 402) {
            val reply = treeResult ?: return
            treeResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { reply.success(null); return }
            if (uri.authority == TERMUX_DOCUMENTS_AUTHORITY) {
                reply.error("termux_companion_required", "Open the paired Termux device in Files to access Termux Home", null)
                return
            }
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            } catch (_: Exception) { /* some providers grant non-persistable session access */ }
            val docId = try { DocumentsContract.getTreeDocumentId(uri) } catch (_: Exception) { uri.lastPathSegment ?: "folder" }
            val label = docId.substringAfter(':').ifEmpty { docId }
            targetPrefs.edit()
                .putString("saf_uri", uri.toString())
                .putString("saf_name", label)
                .apply()
            if (::lan.isInitialized) lan.refreshExports()
            reply.success(mapOf("uri" to uri.toString(), "name" to label, "kind" to "saf"))
            return
        }
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
                    copyVerifiedFile(source, uri)
                } else {
                    val parent = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
                    if (source.parentFile == File(filesDir, "devicebridge/shared-files")) {
                        copyFileOrDirToDocument(source, parent)
                    } else {
                        val name = source.name + "-" + UUID.randomUUID().toString().take(8)
                        val dest = DocumentsContract.createDocument(contentResolver, parent, DocumentsContract.Document.MIME_TYPE_DIR, name) ?: error("Cannot create destination folder")
                        copyFileOrDirToDocument(source, dest)
                    }
                }
                runOnUiThread { reply.success(uri.toString()) }
            } catch (e: Exception) { runOnUiThread { reply.error("save_failed", "Copy incomplete; verified private download preserved. ${e.message}", null) } }
        }
    }

    private fun countTcpSocketsOnPort(port: Int, targetStateHex: String = "01"): Int {
        val hexPort = port.toString(16).uppercase().padStart(4, '0')
        var count = 0
        for (path in listOf("/proc/net/tcp", "/proc/net/tcp6")) {
            try {
                val file = File(path)
                if (!file.canRead()) continue
                file.bufferedReader().useLines { lines ->
                    lines.drop(1).forEach { raw ->
                        val parts = raw.trim().split(Regex("\\s+"))
                        if (parts.size >= 4) {
                            val local = parts[1]
                            val state = parts[3]
                            if (state.equals(targetStateHex, ignoreCase = true) && local.endsWith(":$hexPort", ignoreCase = true)) {
                                count++
                            }
                        }
                    }
                }
            } catch (_: Exception) {}
        }
        return count
    }

    private fun countEstablishedTcpOnPort(port: Int): Int = countTcpSocketsOnPort(port, "01")

    private fun readSshdRuntime(): Map<String, Any?> {
        val pidFile = File(filesDir, "terminal/files/usr/var/run/sshd.pid")
        var pid = 0
        var alive = false
        try {
            if (pidFile.exists()) {
                pid = pidFile.readText().trim().toIntOrNull() ?: 0
                if (pid > 0) {
                    alive = File("/proc/$pid").exists()
                }
            }
        } catch (_: Exception) {}
        val conns = if (alive) countEstablishedTcpOnPort(8022) else 0
        return mapOf(
            "running" to alive,
            "pid" to pid,
            "port" to 8022,
            "conns" to conns,
        )
    }

    private fun readAgentStatusFiles(): Map<String, Any?> {
        val snapshots = listOf("agent-status.json", "agent-direct-status.json").mapNotNull { name ->
            try {
                JSONObject(File(filesDir, "devicebridge/$name").readText())
            } catch (_: Exception) {
                null
            }
        }
        val live = snapshots.filter { snapshot ->
            val pid = snapshot.optInt("pid", 0)
            snapshot.optBoolean("running", false) && pid > 0 && File("/proc/$pid").exists()
        }.distinctBy { it.optInt("pid") }
        val preferred = live.firstOrNull() ?: return emptyMap()
        return mapOf(
            "file_running" to true,
            "pid" to preferred.optInt("pid"),
            "endpoint" to preferred.optString("endpoint", ""),
            "interface" to preferred.optString("interface", ""),
            "cidr" to preferred.optString("cidr", ""),
            "discovery" to live.any { it.optBoolean("discovery", false) },
            "active_conns" to live.sumOf { it.optLong("active_conns", 0L) },
            "active_requests" to live.sumOf { it.optLong("active_requests", 0L) },
            "active_ssh" to live.sumOf { it.optLong("active_ssh", 0L) },
            "agent_ssh_enabled" to live.any { it.optBoolean("agent_ssh_enabled", false) },
            "total_requests" to live.sumOf { it.optLong("total_requests", 0L) },
            "bytes_sent" to live.sumOf { it.optLong("bytes_sent", 0L) },
            "bytes_received" to live.sumOf { it.optLong("bytes_received", 0L) },
        )
    }

    private fun buildRuntimeStatus(includeResources: Boolean): Map<String, Any?> {
        val uid = OsProcess.myUid()
        val uidRx = TrafficStats.getUidRxBytes(uid).let { if (it < 0) 0L else it }
        val uidTx = TrafficStats.getUidTxBytes(uid).let { if (it < 0) 0L else it }
        val totalRx = TrafficStats.getTotalRxBytes().let { if (it < 0) 0L else it }
        val totalTx = TrafficStats.getTotalTxBytes().let { if (it < 0) 0L else it }

        val batteryIntent = try {
            registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        } catch (_: Exception) {
            null
        }
        val plugged = batteryIntent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val batteryPct = if (level >= 0 && scale > 0) (level * 100) / scale else -1
        val batteryStatus = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val batteryCharging = batteryStatus == BatteryManager.BATTERY_STATUS_CHARGING ||
            batteryStatus == BatteryManager.BATTERY_STATUS_FULL
        val caps = directLink.capabilitiesMap()
        val adbEnabled = caps["adb_enabled"] == true
        val usbCablePlugged = ((plugged and BatteryManager.BATTERY_PLUGGED_USB) != 0) ||
            (caps["usb_connected"] == true) ||
            (caps["usb_adb"] == true)
        val lanSnap = lan.statusSnapshot()
        @Suppress("UNCHECKED_CAST")
        val selectedNet = lanSnap["network"] as? Map<String, Any?>
        val selectedIface = selectedNet?.get("interface") as? String ?: ""
        val linkInfo = if (selectedIface.isNotEmpty()) {
            try { directLink.linkDetails(selectedIface) } catch (_: Exception) { emptyMap() }
        } else {
            emptyMap()
        }
        val agentFile = readAgentStatusFiles()
        val sshd = readSshdRuntime()
        val tsnetCfg = deviceSettings.tsnetConfig()
        val allFiles = Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()

        return mapOf(
            "os" to "android",
            "timestamp_ms" to System.currentTimeMillis(),
            "resources" to if (includeResources) sampleResourceDiagnostics() else emptyMap<String, Any?>(),
            "traffic" to mapOf(
                "uid_rx_bytes" to uidRx,
                "uid_tx_bytes" to uidTx,
                "total_rx_bytes" to totalRx,
                "total_tx_bytes" to totalTx,
            ),
            "usb" to mapOf(
                "cable_plugged" to usbCablePlugged,
                "adb_enabled" to adbEnabled,
                "usb_adb_connected" to (caps["usb_adb"] == true),
                "usb_adb_reverse_active" to (countTcpSocketsOnPort(18731, "0A") > 0),
                "serial" to (caps["usb_serial"] as? String ?: ""),
                "battery_level" to batteryPct,
                "battery_charging" to batteryCharging,
            ),
            "physical_networks" to lan.allPhysicalInterfaces(),
            "direct_link" to directLink.activeSessionMap(),
            "link_details" to linkInfo,
            "agent" to (lanSnap + agentFile),
            "ssh" to mapOf(
                "tailscale_ssh_enabled" to (tsnetCfg["tailscale_ssh_enabled"] == true),
                "openssh_enabled" to (tsnetCfg["openssh_enabled"] == true),
                "openssh_running" to (sshd["running"] == true),
                "openssh_port" to (sshd["port"] ?: 8022),
                "openssh_conns" to (sshd["conns"] ?: 0),
                "agent_ssh_conns" to (agentFile["active_ssh"] ?: 0),
            ),
            "tailnet" to mapOf(
                "enabled" to tailnet.enabled(),
                "process_running" to tailnet.isProcessRunning(),
                "socks5_enabled" to (tailnet.enabled() && tsnetCfg["socks5_enabled"] == true),
            ),
            "wireguard" to mapOf(
                "enabled" to wireguard.enabled(),
                "process_running" to wireguard.isProcessRunning(),
            ),
            "capabilities" to mapOf(
                "all_files_access" to allFiles,
                "termux_installed" to isTermuxInstalled(),
                "wifi_direct" to (caps["wifi_direct"] == true),
                "hotspot_ap" to (caps["hotspot_ap"] == true),
            ),
        )
    }

    private fun sampleResourceDiagnostics(): Map<String, Any?> {
        val currentUa = runCatching {
            getSystemService(BatteryManager::class.java)
                .getLongProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        }.getOrNull()?.takeUnless { it == Long.MIN_VALUE }
        return resourceUsage.sample() + mapOf(
            "device_current_ma" to currentUa?.div(1000.0),
            "battery_stats" to resourceUsage.batteryDiagnostics(
                packageName, deviceSettings.rootDiagnosticsEnabled()
            )
        )
    }
}
