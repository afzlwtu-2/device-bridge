package dev.devicebridge.devicebridge

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import org.json.JSONObject
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Manages 5GHz/6GHz Wi-Fi 6 LocalOnlyHotspot and Wi-Fi Direct (P2P GO) setup on Android,
 * cleanly respecting Root -> Shizuku -> Standard Android API privilege tiers,
 * plus an authenticated loopback HTTP endpoint so paired peers can coordinate direct links.
 */
class DirectLinkController(
    private val context: Context,
    private val startDirectAgent: (iface: String, cidr: String, port: Int) -> Unit,
    private val stopDirectAgent: () -> Unit,
    private val ensureWifiPermissions: () -> Boolean = { true }
) {
    private val tag = "DeviceBridge.DirectLink"
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val settingsPrefs = context.getSharedPreferences("devicebridge-settings", Context.MODE_PRIVATE)
    private val linkPrefs = context.getSharedPreferences("devicebridge-direct-link", Context.MODE_PRIVATE)
    private val reconnectPrefs = context.getSharedPreferences("devicebridge-direct-reconnect", Context.MODE_PRIVATE)
    private val lanPrefs = context.getSharedPreferences("devicebridge-lan", Context.MODE_PRIVATE)
    private val token = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
    private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    private val workers = ThreadPoolExecutor(1, 3, 15, TimeUnit.SECONDS, ArrayBlockingQueue(8))
    private val leasePrefs = context.getSharedPreferences("devicebridge-link-lease", Context.MODE_PRIVATE)
    private val leaseScheduler = Executors.newSingleThreadScheduledExecutor()
    private var leaseFuture: java.util.concurrent.ScheduledFuture<*>? = null
    @Volatile private var closed = false
    @Volatile private var activeMode: String? = null
    @Volatile private var activeIface: String? = null
    @Volatile private var activeIp: String? = null
    @Volatile private var activeCidr: String? = null
    @Volatile private var activeBand: String? = null
    @Volatile private var activeFreqMhz: Int = 0
    @Volatile private var activeBandwidthMhz: Int = 0
    @Volatile private var activeWifiStd: String? = null
    @Volatile private var activeSsid: String? = null
    @Volatile private var activePassphrase: String? = null
    @Volatile private var activePrivilege: String? = null
    @Volatile private var joinedSsid: String? = null
    @Volatile private var lohsReservation: WifiManager.LocalOnlyHotspotReservation? = null
    @Volatile private var p2pChannel: WifiP2pManager.Channel? = null
    @Volatile private var specifierCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var joinedNetwork: Network? = null
    @Volatile private var lastRootCheckMs: Long = 0L
    @Volatile private var lastRootOk: Boolean = false
    @Volatile private var cachedUsbSerial: String = ""

    init {
        val id = leasePrefs.getString("id", "").orEmpty()
        if (id.isNotEmpty() && leasePrefs.getString("stage", "") == "preparing") scheduleLease(id)

        Thread({
            while (!closed) {
                try {
                    val socket = server.accept()
                    try { workers.execute { handleHttp(socket) } } catch (_: Exception) { socket.close() }
                } catch (_: Exception) {
                    if (closed) break
                }
            }
        }, "DeviceBridge direct-link ctl").apply { isDaemon = true }.start()
    }

    private fun logVerbose(msg: String) {
        if (settingsPrefs.getBoolean("verbose_logging", true)) {
            Log.d(tag, msg)
        }
    }

    /**
     * Android network handle for a group this device joined as a station. The Go
     * core needs it to bind sockets to that network; unmarked sockets otherwise
     * follow mobile data and never reach the peer hosting the group.
     */
    fun joinedNetworkBinding(): Pair<String, String>? {
        if (activeMode != "wifi_join") return null
        val network = joinedNetwork ?: return null
        val cidr = activeCidr ?: return null
        return network.networkHandle.toString() to cidr
    }

    private fun checkRootLive(): Boolean {
        if (!settingsPrefs.getBoolean("root_enabled", false)) {
            lastRootOk = false
            return false
        }
        val now = System.currentTimeMillis()
        if (lastRootCheckMs > 0 && (now - lastRootCheckMs) < 30_000L) {
            return lastRootOk
        }
        var child: Process? = null
        val ok = try {
            child = ProcessBuilder("su", "-c", "id -u").start()
            child.waitFor(3, TimeUnit.SECONDS) &&
                child.inputStream.bufferedReader().use { it.readText().trim() } == "0" &&
                child.exitValue() == 0
        } catch (_: Exception) {
            false
        } finally {
            child?.destroyForcibly()
        }
        lastRootCheckMs = now
        lastRootOk = ok
        if (!ok) {
            settingsPrefs.edit()
                .putBoolean("root_enabled", false)
                .putString("root_status", "Root removed or denied (auto-disabled)")
                .apply()
        }
        return ok
    }

    private fun isShizukuActive(): Boolean {
        if (!settingsPrefs.getBoolean("shizuku_enabled", false)) return false
        return try {
            Shizuku.pingBinder() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (_: Exception) {
            false
        }
    }

    private fun activePrivilegeMode(featureKeyRoot: String, featureKeyShizuku: String): String {
        if (checkRootLive() && settingsPrefs.getBoolean(featureKeyRoot, true)) {
            return "root"
        }
        if (isShizukuActive() && settingsPrefs.getBoolean(featureKeyShizuku, true)) {
            return "shizuku"
        }
        return "standard"
    }

    private fun freqToChannel(freq: Int): Int = when {
        freq == 2484 -> 14
        freq in 2412..2472 -> (freq - 2407) / 5
        freq in 5150..5925 -> (freq - 5000) / 5
        freq == 5935 -> 2
        freq in 5955..7115 -> (freq - 5950) / 5
        else -> 0
    }

    private fun channelToFreq(ch: Int): Int = when {
        ch == 14 -> 2484
        ch in 1..13 -> 2407 + ch * 5
        ch in 32..177 -> 5000 + ch * 5
        else -> 0
    }

    private fun usable5GhzFrequencies(opMode: Int = 8): List<Int> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || wifi == null) return emptyList()
        val modes = listOf(opMode, 2, 1).distinct()
        for (m in modes) {
            try {
                val freqs = wifi.getUsableChannels(2 /* WIFI_BAND_5_GHZ */, m)
                    .map { it.frequencyMhz }
                    .filter { it in 5150..5925 }
                    .distinct()
                    .sortedDescending()
                if (freqs.isNotEmpty()) return freqs
            } catch (_: Exception) {}
        }
        return emptyList()
    }

    private fun preferredAuto5GhzFreqs(opMode: Int = 8): List<Int> {
        val usable = usable5GhzFrequencies(opMode)
        if (usable.isEmpty()) return listOf(5805, 5745, 5180)
        // Prefer highest 80 MHz UNII-3 primary (5805 / Ch 161) ahead of 20 MHz-only 5825 (Ch 165).
        val ordered = mutableListOf<Int>()
        if (usable.contains(5805)) ordered.add(5805)
        for (f in usable) {
            if (f != 5805 && f != 5825) ordered.add(f)
        }
        if (usable.contains(5825)) ordered.add(5825)
        return ordered.distinct()
    }

    private fun readSystemProp(key: String): String = try {
        val cls = Class.forName("android.os.SystemProperties")
        val method = cls.getMethod("get", String::class.java, String::class.java)
        (method.invoke(null, key, "") as? String)?.trim().orEmpty()
    } catch (_: Exception) {
        ""
    }

    private fun readUsbSerial(): String {
        val existing = cachedUsbSerial
        if (existing.isNotEmpty()) return existing
        val direct = readSystemProp("ro.serialno").ifEmpty { readSystemProp("ro.boot.serialno") }
        if (direct.isNotEmpty() && !direct.equals("unknown", ignoreCase = true)) {
            cachedUsbSerial = direct
            return direct
        }
        val priv = activePrivilegeMode("root_feature_direct_link", "shizuku_feature_direct_link")
        if (priv != "standard") {
            val out = runPrivilegedShell(priv, "getprop ro.serialno")?.second?.trim().orEmpty()
            if (out.isNotEmpty() && !out.equals("unknown", ignoreCase = true)) {
                cachedUsbSerial = out
                return out
            }
        }
        return ""
    }

    fun usbStatus(): Map<String, Any?> {
        val adbEnabled = try { Settings.Global.getInt(context.contentResolver, Settings.Global.ADB_ENABLED, 0) == 1 } catch (_: Exception) { false }
        val usbState = try { context.registerReceiver(null, IntentFilter("android.hardware.usb.action.USB_STATE")) } catch (_: Exception) { null }
        val usbConnected = usbState?.getBooleanExtra("connected", false) == true
        val usbConfigured = usbState?.getBooleanExtra("configured", false) == true
        val usbHostConnected = usbState?.getBooleanExtra("host_connected", false) == true
        val hasAdbExtra = usbState?.hasExtra("adb") == true
        val adbExtra = usbState?.getBooleanExtra("adb", false) == true
        val hostDevices = try { (context.getSystemService(Context.USB_SERVICE) as? UsbManager)?.deviceList?.size ?: 0 } catch (_: Exception) { 0 }

        // Android 11–16+ / HyperOS often omits the `"adb"` extra from USB_STATE when only
        // ADB debugging is active, while `sys.usb.state` (public usb_control_prop) reports `adb`
        // or `mtp,adb` and `USB_STATE` reports `connected=true, configured=true`.
        val sysUsbState = readSystemProp("sys.usb.state")
        val usbFunctions = sysUsbState.split(',').map { it.trim() }.filter { it.isNotEmpty() && it != "none" }
        val usbLinkUp = usbConnected || usbConfigured
        val adbFunctionActive = when {
            adbExtra -> true
            usbFunctions.isNotEmpty() -> usbFunctions.contains("adb")
            hasAdbExtra -> false
            else -> usbConfigured
        }
        val usbAdbConnected = adbEnabled && usbLinkUp && adbFunctionActive
        val usbCableConnected = usbLinkUp || usbHostConnected || hostDevices > 0 || usbAdbConnected
        val usbSerial = if (usbCableConnected || adbEnabled) readUsbSerial() else ""
        return mapOf(
            "usb_connected" to usbCableConnected,
            "usb_configured" to usbConfigured,
            "usb_host_connected" to (usbHostConnected || hostDevices > 0),
            "adb_enabled" to adbEnabled,
            "usb_adb" to usbAdbConnected,
            "usb_serial" to usbSerial,
            "usb_functions" to usbFunctions,
        )
    }

    private fun supportsWifiRadio(): Boolean {
        // Waydroid ships Android's Wi-Fi feature and framework service over a virtual Ethernet link.
        val waydroid = Build.DEVICE.startsWith("waydroid", ignoreCase = true) ||
            Build.PRODUCT.contains("_waydroid", ignoreCase = true)
        return !waydroid && wifi != null &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI)
    }

    fun capabilitiesMap(): Map<String, Any?> {
        val usb = usbStatus()
        val adbEnabled = usb["adb_enabled"] == true
        val usbAdbConnected = usb["usb_adb"] == true
        val usbCableConnected = usb["usb_connected"] == true
        val usbSerial = usb["usb_serial"] as? String ?: ""
        val wifiSupported = supportsWifiRadio()
        val wifi5g = try { wifiSupported && wifi?.is5GHzBandSupported == true } catch (_: Exception) { false }
        val usable5gChannels = if (wifi5g) usable5GhzFrequencies(2).map { freqToChannel(it) }.filter { it > 0 }.distinct() else emptyList()
        val wifi6 = try { wifiSupported && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && wifi?.isWifiStandardSupported(ScanResult.WIFI_STANDARD_11AX) == true } catch (_: Exception) { false }
        val wifi6g = try {
            if (wifiSupported && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && wifi?.is6GHzBandSupported == true) {
                val channels6g = try {
                    wifi.getUsableChannels(8 /* WifiScanner.WIFI_BAND_6_GHZ */, 1 /* OP_MODE_STA */)
                } catch (_: Exception) {
                    emptyList()
                }
                channels6g.any { it.frequencyMhz in 5925..7125 }
            } else {
                false
            }
        } catch (_: Exception) { false }
        val wifiDirect = wifiSupported && context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
        val execMode = when {
            checkRootLive() -> "root"
            isShizukuActive() -> "shizuku"
            else -> "standard"
        }
        return mapOf(
            "os" to "android",
            "execution_mode" to execMode,
            "wifi" to wifiSupported,
            "wifi_5ghz" to wifi5g,
            "wifi_6" to wifi6,
            "wifi_6ghz" to wifi6g,
            "wifi_direct" to wifiDirect,
            "wifi_direct_go" to wifiDirect,
            "hotspot_ap" to wifiSupported,
            "hotspot_5ghz_ap" to wifi5g,
            "hotspot_sta" to wifiSupported,
            "usable_5ghz_channels" to usable5gChannels,
            "adb_enabled" to adbEnabled,
            "usb_connected" to usbCableConnected,
            "usb_adb_connected" to usbAdbConnected,
            "usb_adb" to usbAdbConnected,
            "usb_serial" to usbSerial,
            "checked_at_utc" to (System.currentTimeMillis() / 1000L)
        )
    }

    fun environment(): Map<String, String> {
        val caps = capabilitiesMap()
        val link = if (caps["wifi"] == true) linkDetails(activeIface.orEmpty()) else emptyMap()
        val linkJson = JSONObject()
            .put("interface", link["interface"] ?: "")
            .put("band", link["band"] ?: "")
            .put("channel", link["channel"] ?: 0)
            .put("frequency_mhz", link["frequency_mhz"] ?: 0)
            .put("wifi_standard", link["wifi_standard"] ?: "")
            .put("ssid", link["ssid"] ?: "")
        val usable5gList = (caps["usable_5ghz_channels"] as? List<*>) ?: emptyList<Int>()
        val capsJson = JSONObject()
            .put("os", "android")
            .put("wifi_5ghz", caps["wifi_5ghz"] == true)
            .put("wifi_6", caps["wifi_6"] == true)
            .put("wifi_6ghz", caps["wifi_6ghz"] == true)
            .put("wifi_direct", caps["wifi_direct"] == true)
            .put("wifi_direct_go", caps["wifi_direct_go"] == true)
            .put("hotspot_ap", caps["hotspot_ap"] == true)
            .put("hotspot_5ghz_ap", caps["hotspot_5ghz_ap"] == true)
            .put("hotspot_sta", caps["hotspot_sta"] == true)
            .put("usable_5ghz_channels", org.json.JSONArray(usable5gList))
            .put("usb_adb", caps["usb_adb"] == true)
            .put("checked_at_utc", caps["checked_at_utc"] ?: (System.currentTimeMillis() / 1000L))
            .put("link", linkJson.takeIf { link.isNotEmpty() })
            .toString()
        return mapOf(
            "DEVICEBRIDGE_LINKCTL_ENDPOINT" to "http://127.0.0.1:${server.localPort}",
            "DEVICEBRIDGE_LINKCTL_TOKEN" to token,
            "DEVICEBRIDGE_CAPABILITIES_JSON" to capsJson
        )
    }

    fun localLeaseStatus(): Map<String, Any?> = mapOf("local_lease_stage" to leasePrefs.getString("stage", ""), "local_lease_deadline" to leasePrefs.getLong("deadline", 0))

    @Synchronized
    fun beginLocalLease(id: String, seconds: Int) {
        check(activeSessionMap()["active"] != true) { "Stop the current managed link before starting another" }
        require(id.matches(Regex("[a-f0-9]{32}")) && seconds in 15..180) { "Invalid network operation lease" }
        check(leasePrefs.getString("stage", "") !in setOf("preparing", "needs_recovery")) { "Restore the incomplete local network operation first" }
        check(leasePrefs.edit().putString("id", id).putString("stage", "preparing").putLong("deadline", System.currentTimeMillis() + seconds * 1000L).commit()) { "Could not save rollback deadline" }
        scheduleLease(id)
    }

    private fun scheduleLease(id: String) {
        leaseFuture?.cancel(false)
        val delay = (leasePrefs.getLong("deadline", 0) - System.currentTimeMillis()).coerceIn(0L, 180000L)
        leaseFuture = leaseScheduler.schedule({
            synchronized(this) {
                if (!closed && leasePrefs.getString("id", "") == id && leasePrefs.getString("stage", "") == "preparing") {
                    try { restore(); leasePrefs.edit().putString("stage", "restored").commit() }
                    catch (_: Exception) { leasePrefs.edit().putString("stage", "needs_recovery").commit() }
                }
            }
        }, delay, TimeUnit.MILLISECONDS)
    }

    @Synchronized
    fun commitLocalLease(id: String) {
        if (leasePrefs.getString("id", "") == id && leasePrefs.getString("stage", "") == "committed") return
        check(leasePrefs.getString("id", "") == id && leasePrefs.getString("stage", "") == "preparing" && leasePrefs.getLong("deadline", 0) > System.currentTimeMillis()) { "Local network setup expired; restore before retrying" }
        check(leasePrefs.edit().putString("stage", "committed").commit()) { "Could not commit local network setup" }
        leaseFuture?.cancel(false)
    }

    @Synchronized
    fun prepare(
        kind: String,
        bandPref: String = "auto",
        customSsid: String = "",
        customPassphrase: String = "",
        freqMhz: Int = 0,
        channel: Int = 0,
        bandwidthMhz: Int = 0,
        peerId: String = "",
        peerEndpoint: String = "",
        peerKind: String = ""
    ): Map<String, Any?> {
        logVerbose("prepare kind=$kind band=$bandPref freq=$freqMhz ch=$channel bw=$bandwidthMhz")
        if (kind in setOf("hotspot", "wifi_direct", "wifi_join")) {
            check(supportsWifiRadio()) { "This device has no supported Wi-Fi radio." }
        }
        val result = when (kind) {
            "hotspot" -> startHotspot(bandPref, customSsid, customPassphrase, freqMhz, channel, bandwidthMhz)
            "wifi_direct" -> startWifiDirect(bandPref, customSsid, customPassphrase, freqMhz, channel)
            "wifi_join" -> joinWifi(customSsid, customPassphrase, bandPref)
            "restore" -> restore()
            else -> throw IllegalArgumentException("Unsupported Android link kind: $kind")
        }
        if (peerId.isNotBlank() && kind in setOf("hotspot", "wifi_direct", "wifi_join")) {
            reconnectPrefs.edit().clear()
                .putString("peer_id", peerId)
                .putString("kind", if (kind == "wifi_join") peerKind else kind)
                .putBoolean("joined", kind == "wifi_join")
                .putString("ssid", result["ssid"] as? String ?: customSsid)
                .putString("passphrase", if (kind == "wifi_join") customPassphrase else "")
                .putString("endpoint", peerEndpoint)
                .putString("band", result["band"] as? String ?: bandPref)
                .apply()
        }
        return result
    }

    private fun saveSessionPrefs(
        mode: String,
        iface: String,
        ip: String,
        cidr: String,
        ssid: String,
        passphrase: String,
        band: String,
        freqMhz: Int,
        bwMhz: Int,
        wifiStd: String,
        privilege: String
    ) {
        linkPrefs.edit()
            .putString("mode", mode)
            .putString("interface", iface)
            .putString("ip", ip)
            .putString("cidr", cidr)
            .putString("ssid", ssid)
            .putString("passphrase", passphrase)
            .putString("band", band)
            .putInt("frequency_mhz", freqMhz)
            .putInt("bandwidth_mhz", bwMhz)
            .putString("wifi_standard", wifiStd)
            .putString("privilege", privilege)
            .putLong("started_at", System.currentTimeMillis())
            .apply()
    }

    private fun clearSessionPrefs() {
        linkPrefs.edit().clear().apply()
    }

    private fun listUpDirectInterfaces(): List<Triple<String, String, String>> {
        val out = mutableListOf<Triple<String, String, String>>()
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces()
            while (ifaces != null && ifaces.hasMoreElements()) {
                val iface = ifaces.nextElement()
                if (!iface.isUp || iface.isLoopback) continue
                val name = iface.name ?: continue
                if (!name.startsWith("p2p") && !name.startsWith("ap") && !name.startsWith("swlan")) continue
                for (la in iface.interfaceAddresses) {
                    val addr = la.address
                    if (addr is Inet4Address && addr.isSiteLocalAddress) {
                        val ip = addr.hostAddress ?: continue
                        out.add(Triple(name, ip, "$ip/${la.networkPrefixLength}"))
                        break
                    }
                }
            }
        } catch (_: Exception) {}
        return out
    }

    private data class P2pGroupSnapshot(
        val isGroupOwner: Boolean,
        val ssid: String,
        val passphrase: String,
        val iface: String,
        val freqMhz: Int,
        val clientsCount: Int
    )

    private fun ensureP2pChannel(): WifiP2pManager.Channel? {
        val mgr = context.getSystemService(WifiP2pManager::class.java) ?: return null
        return p2pChannel ?: mgr.initialize(context, Looper.getMainLooper(), null)?.also { p2pChannel = it }
    }

    private fun queryP2pGroupDetails(): P2pGroupSnapshot? {
        val mgr = context.getSystemService(WifiP2pManager::class.java)
        val ch = if (mgr != null) ensureP2pChannel() else null
        if (mgr != null && ch != null) {
            val latch = CountDownLatch(1)
            var snap: P2pGroupSnapshot? = null
            try {
                mgr.requestGroupInfo(ch) { group ->
                    if (group != null) {
                        val freq = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) group.frequency else 0
                        @Suppress("DEPRECATION")
                        val iface = group.`interface` ?: ""
                        snap = P2pGroupSnapshot(
                            isGroupOwner = group.isGroupOwner,
                            ssid = group.networkName.orEmpty(),
                            passphrase = group.passphrase.orEmpty(),
                            iface = iface,
                            freqMhz = freq,
                            clientsCount = group.clientList?.size ?: 0
                        )
                    }
                    latch.countDown()
                }
                latch.await(1500, TimeUnit.MILLISECONDS)
            } catch (_: SecurityException) {
            } catch (_: Exception) {}
            if (snap != null) return snap
        }
        val priv = activePrivilegeMode("root_feature_direct_link", "shizuku_feature_direct_link")
        if (priv != "standard") {
            val info = runPrivilegedShell(priv, "cmd wifip2p init >/dev/null 2>&1; cmd wifip2p get-group-info")
            if (info != null && info.first == 0 && info.second.isNotBlank() && !info.second.contains("No group")) {
                val txt = info.second
                val ssid = Regex("(?:networkName|SSID):\\s*([^\\n,]+)").find(txt)?.groupValues?.getOrNull(1)?.trim().orEmpty()
                val pass = Regex("passphrase:\\s*([^\\n,]+)").find(txt)?.groupValues?.getOrNull(1)?.trim().orEmpty()
                val iface = Regex("interface:\\s*([^\\n,]+)").find(txt)?.groupValues?.getOrNull(1)?.trim().orEmpty()
                val freq = Regex("frequency:\\s*(\\d+)").find(txt)?.groupValues?.getOrNull(1)?.toIntOrNull() ?: 0
                val isGo = txt.contains("isGO: true") || txt.contains("isGroupOwner=true")
                if (ssid.isNotEmpty() || iface.isNotEmpty()) {
                    return P2pGroupSnapshot(isGo, ssid, pass, iface, freq, 0)
                }
            }
        }
        return null
    }

    private fun lanPolicyReferencesIface(iface: String): Boolean {
        for (key in listOf("policy", "prev_policy")) {
            val raw = lanPrefs.getString(key, null) ?: continue
            try {
                if (JSONObject(raw).optString("interface") == iface) return true
            } catch (_: Exception) {}
        }
        return false
    }

    private fun hotspotStatusHint(priv: String): String {
        if (priv == "standard") return ""
        val st = runPrivilegedShell(priv, "cmd wifi status") ?: return ""
        val txt = st.second
        val m = Regex("(?:DB-AP-[A-Za-z0-9_-]+|AndroidShare_[A-Za-z0-9_-]+)").find(txt)
        return m?.value.orEmpty()
    }

    private fun buildActiveSessionMap(resumed: Boolean = false, clientsCount: Int = 0): Map<String, Any?> {
        val mode = activeMode ?: return mapOf("active" to false)
        val iface = activeIface.orEmpty()
        val ip = activeIp.orEmpty()
        val cidr = activeCidr.orEmpty()
        val freq = activeFreqMhz
        val band = activeBand.orEmpty().ifBlank { bandForFreq(freq) }
        val ch = freqToChannel(freq)
        return mapOf(
            "active" to true,
            "resumed" to resumed,
            "kind" to mode,
            "mode" to (activePrivilege ?: "standard"),
            "interface" to iface,
            "ip" to ip,
            "cidr" to cidr,
            "endpoint" to if (ip.isNotEmpty()) "$ip:8731" else "",
            "ssid" to activeSsid.orEmpty(),
            "passphrase" to activePassphrase.orEmpty(),
            "band" to band,
            "channel" to ch,
            "frequency_mhz" to freq,
            "bandwidth_mhz" to activeBandwidthMhz,
            "wifi_standard" to activeWifiStd.orEmpty(),
            "clients_count" to clientsCount
        )
    }

    @Synchronized
    fun activeSessionMap(): Map<String, Any?> {
        val active = resumeOrphanedIfPresent()
        val peerId = reconnectPrefs.getString("peer_id", null) ?: return active
        return active + ("saved" to mapOf(
            "peer_id" to peerId,
            "kind" to reconnectPrefs.getString("kind", ""),
            "joined" to reconnectPrefs.getBoolean("joined", false),
            "ssid" to reconnectPrefs.getString("ssid", ""),
            "passphrase" to reconnectPrefs.getString("passphrase", ""),
            "endpoint" to reconnectPrefs.getString("endpoint", ""),
            "band" to reconnectPrefs.getString("band", "")
        ))
    }

    @Synchronized
    fun resumeOrphanedIfPresent(): Map<String, Any?> {
        val upDirect = listUpDirectInterfaces()
        val savedMode = linkPrefs.getString("mode", null)
        val savedIface = linkPrefs.getString("interface", "").orEmpty()
        val savedSsid = linkPrefs.getString("ssid", "").orEmpty()
        val savedPass = linkPrefs.getString("passphrase", "").orEmpty()
        val savedBand = linkPrefs.getString("band", "").orEmpty()
        val savedFreq = linkPrefs.getInt("frequency_mhz", 0)
        val savedBw = linkPrefs.getInt("bandwidth_mhz", 0)
        val savedStd = linkPrefs.getString("wifi_standard", "").orEmpty()
        val savedPriv = linkPrefs.getString("privilege", "standard").orEmpty()
        val priv = activePrivilegeMode("root_feature_direct_link", "shizuku_feature_direct_link")

        val p2pIf = upDirect.firstOrNull { it.first.startsWith("p2p") }
        val p2pSnap = if (p2pIf != null || savedMode == "wifi_direct" || activeMode == "wifi_direct") {
            queryP2pGroupDetails()
        } else {
            null
        }
        if (p2pIf != null || (p2pSnap != null && p2pSnap.isGroupOwner)) {
            val matched = p2pIf ?: upDirect.firstOrNull { it.first == p2pSnap?.iface }
            if (matched != null) {
                val wasResumed = activeMode == null
                val iface = matched.first
                val ip = matched.second
                val cidr = matched.third
                val freq = if (p2pSnap != null && p2pSnap.freqMhz > 0) {
                    p2pSnap.freqMhz
                } else if (activeFreqMhz > 0) {
                    activeFreqMhz
                } else {
                    savedFreq
                }
                val band = bandForFreq(freq).ifBlank {
                    activeBand.orEmpty().ifBlank { savedBand.ifBlank { "5 GHz" } }
                }
                val bw = when {
                    activeBandwidthMhz > 0 -> activeBandwidthMhz
                    savedBw > 0 -> savedBw
                    freq >= 5000 -> 80
                    else -> 0
                }
                val ssid = (p2pSnap?.ssid?.takeIf { it.isNotBlank() }
                    ?: activeSsid?.takeIf { it.isNotBlank() }
                    ?: savedSsid)
                val pass = (p2pSnap?.passphrase?.takeIf { it.isNotBlank() }
                    ?: activePassphrase?.takeIf { it.isNotBlank() }
                    ?: savedPass)
                val usedPriv = activePrivilege ?: savedPriv.ifBlank { priv }
                val std = activeWifiStd.orEmpty().ifBlank { savedStd }

                activeMode = "wifi_direct"
                activeIface = iface
                activeIp = ip
                activeCidr = cidr
                activeFreqMhz = freq
                activeBand = band
                activeBandwidthMhz = bw
                activeWifiStd = std
                activeSsid = ssid
                activePassphrase = pass
                activePrivilege = usedPriv
                saveSessionPrefs("wifi_direct", iface, ip, cidr, ssid, pass, band, freq, bw, std, usedPriv)
                startDirectAgent(iface, cidr, 8731)
                return buildActiveSessionMap(resumed = wasResumed, clientsCount = p2pSnap?.clientsCount ?: 0)
            }
        }

        val apIf = upDirect.firstOrNull { it.first.startsWith("ap") || it.first.startsWith("swlan") }
        if (apIf != null) {
            val statusSsid = hotspotStatusHint(priv)
            val owned = activeMode == "hotspot" ||
                savedMode == "hotspot" ||
                lanPolicyReferencesIface(apIf.first) ||
                statusSsid.isNotBlank()
            if (owned) {
                val wasResumed = activeMode == null
                val iface = apIf.first
                val ip = apIf.second
                val cidr = apIf.third
                val freq = if (activeFreqMhz > 0) activeFreqMhz else savedFreq
                val band = bandForFreq(freq).ifBlank {
                    activeBand.orEmpty().ifBlank {
                        savedBand.ifBlank { if (capabilitiesMap()["wifi_5ghz"] == true) "5 GHz" else "2.4 GHz" }
                    }
                }
                val bw = if (activeBandwidthMhz > 0) activeBandwidthMhz else savedBw
                val ssid = activeSsid?.takeIf { it.isNotBlank() }
                    ?: savedSsid.takeIf { it.isNotBlank() }
                    ?: statusSsid
                val pass = activePassphrase?.takeIf { it.isNotBlank() } ?: savedPass
                val usedPriv = activePrivilege ?: savedPriv.ifBlank { priv }
                val std = activeWifiStd.orEmpty().ifBlank { savedStd }

                activeMode = "hotspot"
                activeIface = iface
                activeIp = ip
                activeCidr = cidr
                activeFreqMhz = freq
                activeBand = band
                activeBandwidthMhz = bw
                activeWifiStd = std
                activeSsid = ssid
                activePassphrase = pass
                activePrivilege = usedPriv
                saveSessionPrefs("hotspot", iface, ip, cidr, ssid, pass, band, freq, bw, std, usedPriv)
                startDirectAgent(iface, cidr, 8731)
                return buildActiveSessionMap(resumed = wasResumed)
            }
        }

        if (activeMode == "wifi_join" || savedMode == "wifi_join") {
            val curLink = linkDetails(savedIface)
            val curSsid = (curLink["ssid"] as? String).orEmpty()
            val targetJoin = joinedSsid?.takeIf { it.isNotBlank() } ?: savedSsid
            val net = if (targetJoin.isNotBlank() && curSsid == targetJoin) {
                interfaceIPv4(savedIface.ifBlank { (curLink["interface"] as? String).orEmpty() })
            } else null
            if (net != null) {
                val wasResumed = activeMode == null
                activeMode = "wifi_join"
                joinedSsid = targetJoin
                activeSsid = targetJoin
                activeIface = net.first
                activeIp = net.second
                activeCidr = net.third
                activePassphrase = savedPass
                activePrivilege = savedPriv
                activeFreqMhz = (curLink["frequency_mhz"] as? Int) ?: savedFreq
                activeBand = (curLink["band"] as? String).orEmpty().ifBlank { savedBand }
                return buildActiveSessionMap(resumed = wasResumed)
            }
        }

        if (activeMode != null || savedMode != null) {
            activeMode = null
            activeIface = null
            activeIp = null
            activeCidr = null
            activeBand = null
            activeFreqMhz = 0
            activeBandwidthMhz = 0
            activeWifiStd = null
            activeSsid = null
            activePassphrase = null
            activePrivilege = null
            joinedSsid = null
            clearSessionPrefs()
        }
        return mapOf("active" to false)
    }

    @Synchronized
    fun restore(forget: Boolean = true): Map<String, Any?> {
        if (forget) reconnectPrefs.edit().clear().apply()
        stopDirectAgent()
        val prevMode = activeMode
        val persistedMode = linkPrefs.getString("mode", null)
        val liveDirect = listUpDirectInterfaces()
        val hadP2p = prevMode == "wifi_direct" ||
            persistedMode == "wifi_direct" ||
            p2pChannel != null ||
            liveDirect.any { it.first.startsWith("p2p") }
        val hadHotspot = prevMode == "hotspot" ||
            persistedMode == "hotspot" ||
            lohsReservation != null ||
            liveDirect.any { it.first.startsWith("ap") || it.first.startsWith("swlan") }
        val prevJoined = joinedSsid ?: linkPrefs.getString("ssid", null)
        val hadJoin = prevMode == "wifi_join" || persistedMode == "wifi_join"
        val joinedVia = activePrivilege ?: linkPrefs.getString("privilege", null)
        activeMode = null
        activeIface = null
        activeIp = null
        activeCidr = null
        activeBand = null
        activeFreqMhz = 0
        activeBandwidthMhz = 0
        activeWifiStd = null
        activeSsid = null
        activePassphrase = null
        activePrivilege = null
        joinedSsid = null
        clearSessionPrefs()
        lohsReservation?.let {
            try { it.close() } catch (_: Exception) {}
            lohsReservation = null
        }
        specifierCallback?.let { cb ->
            try { cm?.unregisterNetworkCallback(cb) } catch (_: Exception) {}
            specifierCallback = null
        }
        joinedNetwork = null
        if (hadP2p) {
            val ch = ensureP2pChannel()
            if (ch != null) {
                val p2p = context.getSystemService(WifiP2pManager::class.java)
                val latch = CountDownLatch(1)
                try {
                    p2p?.removeGroup(ch, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() { latch.countDown() }
                        override fun onFailure(reason: Int) { latch.countDown() }
                    }) ?: latch.countDown()
                    latch.await(1500, TimeUnit.MILLISECONDS)
                } catch (_: Exception) {}
                p2pChannel = null
                try { Thread.sleep(300) } catch (_: Exception) {}
            }
        } else {
            p2pChannel = null
        }
        val priv = activePrivilegeMode("root_feature_direct_link", "shizuku_feature_direct_link")
        if (priv != "standard") {
            if (hadHotspot) {
                runPrivilegedShell(priv, "cmd wifi stop-lohs")
            }
            if (hadP2p) {
                runPrivilegedShell(priv, "cmd wifip2p init >/dev/null 2>&1; cmd wifip2p remove-group >/dev/null 2>&1; cmd wifip2p deinit >/dev/null 2>&1")
            }
        }
        if (hadJoin && joinedVia in setOf("root", "shizuku") && !prevJoined.isNullOrBlank()) {
            val joinPriv = activePrivilegeMode("root_feature_direct_link", "shizuku_feature_wifi_join")
            if (joinPriv != "standard") {
                val nets = runPrivilegedShell(joinPriv, "cmd wifi list-networks")
                if (nets != null) {
                    val escaped = Regex.escape(prevJoined)
                    val netId = Regex("^\\s*(\\d+)\\s+$escaped\\s", RegexOption.MULTILINE)
                        .find(nets.second)?.groupValues?.getOrNull(1)
                    if (netId != null) runPrivilegedShell(joinPriv, "cmd wifi forget-network $netId")
                }
            }
        }
        leasePrefs.edit().putString("stage", "restored").commit()
        leaseFuture?.cancel(false)
        return mapOf("ok" to true, "kind" to "restore", "status" to "restored")
    }

    private fun shellQuote(s: String): String = "'" + s.replace("'", "'\\''") + "'"

    private fun joinWifi(ssid: String, pass: String, band: String): Map<String, Any?> {
        restore(forget = false)
        if (ssid.isBlank()) error("SSID is required to join peer Wi-Fi")
        val priv = activePrivilegeMode("root_feature_direct_link", "shizuku_feature_wifi_join")
        if (priv != "standard") {
            val cmd = if (pass.isBlank()) {
                "cmd wifi connect-network ${shellQuote(ssid)} open"
            } else {
                "cmd wifi connect-network ${shellQuote(ssid)} wpa2 ${shellQuote(pass)}"
            }
            val res = runPrivilegedShell(priv, cmd)
            if (res != null && (res.first == 0 || res.second.contains("success", ignoreCase = true))) {
                joinedSsid = ssid
                activeMode = "wifi_join"
                val deadline = System.currentTimeMillis() + 14000L
                var netInfo: Triple<String, String, String>? = null
                while (System.currentTimeMillis() < deadline) {
                    val st = runPrivilegedShell(priv, "cmd wifi status")
                    if (st != null && st.second.contains("\"$ssid\"")) {
                        val found = waitForInterface(listOf("wlan"))
                        if (found != null) {
                            netInfo = found
                            break
                        }
                    }
                    Thread.sleep(400)
                }
                val net = netInfo ?: error("Joined $ssid via $priv but timed out waiting for IPv4 address")
                activeIface = net.first
                activeIp = net.second
                activeCidr = net.third
                activeSsid = ssid
                activePassphrase = pass
                activeBand = band
                activePrivilege = priv
                saveSessionPrefs("wifi_join", net.first, net.second, net.third, ssid, pass, band, 0, 0, "", priv)
                return mapOf(
                    "ok" to true,
                    "kind" to "wifi_join",
                    "transport" to "lan",
                    "mode" to priv,
                    "interface" to net.first,
                    "ip" to net.second,
                    "cidr" to net.third,
                    "endpoint" to "${net.second}:8731",
                    "ssid" to ssid,
                    "band" to band,
                    "status" to "connected"
                )
            }
            val errDetail = res?.let { it.second.ifBlank { it.third } } ?: "shell unavailable"
            logVerbose("$priv joinWifi fallback after shell error: $errDetail")
        }

        // Standard API (Android 10+): WifiNetworkSpecifier requires no root or Shizuku.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && cm != null) {
            val net = joinWifiStandardSpecifier(ssid, pass)
            if (net != null) {
                joinedSsid = ssid
                activeMode = "wifi_join"
                activeIface = net.first
                activeIp = net.second
                activeCidr = net.third
                activeSsid = ssid
                activePassphrase = pass
                activeBand = band
                activePrivilege = "standard"
                saveSessionPrefs("wifi_join", net.first, net.second, net.third, ssid, pass, band, 0, 0, "", "standard")
                return mapOf(
                    "ok" to true,
                    "kind" to "wifi_join",
                    "transport" to "lan",
                    "mode" to "standard",
                    "interface" to net.first,
                    "ip" to net.second,
                    "cidr" to net.third,
                    "endpoint" to "${net.second}:8731",
                    "ssid" to ssid,
                    "band" to band,
                    "status" to "connected"
                )
            }
        }
        error("Could not join $ssid automatically (enable Shizuku/Root or connect manually in Android Wi-Fi settings)")
    }

    private fun joinWifiStandardSpecifier(ssid: String, pass: String): Triple<String, String, String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || cm == null) return null
        val builder = WifiNetworkSpecifier.Builder().setSsid(ssid)
        if (pass.isNotBlank()) builder.setWpa2Passphrase(pass)
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(builder.build())
            .build()
        val latch = CountDownLatch(1)
        var connected: Triple<String, String, String>? = null
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onLinkPropertiesChanged(network: Network, lp: android.net.LinkProperties) {
                val la = lp.linkAddresses.firstOrNull { it.address is Inet4Address && it.address.isSiteLocalAddress }
                val ip = la?.address?.hostAddress
                if (lp.interfaceName != null && ip != null) {
                    joinedNetwork = network
                    connected = Triple(lp.interfaceName!!, ip, "$ip/${la.prefixLength}")
                    latch.countDown()
                }
            }
            override fun onUnavailable() { latch.countDown() }
        }
        specifierCallback = cb
        try {
            cm.requestNetwork(req, cb)
            latch.await(20, TimeUnit.SECONDS)
        } catch (_: Exception) {
            try { cm.unregisterNetworkCallback(cb) } catch (_: Exception) {}
            specifierCallback = null
            return null
        }
        if (connected == null) {
            try { cm.unregisterNetworkCallback(cb) } catch (_: Exception) {}
            specifierCallback = null
        }
        return connected
    }

    private fun startHotspot(
        bandPref: String,
        customSsid: String = "",
        customPass: String = "",
        reqFreqMhz: Int = 0,
        reqChannel: Int = 0,
        reqBwMhz: Int = 0
    ): Map<String, Any?> {
        restore(forget = false)
        val caps = capabilitiesMap()
        val suffix = "%04x".format(SecureRandom().nextInt(0x10000))
        val ssid = customSsid.ifBlank { "DB-AP-$suffix" }
        val pass = customPass.ifBlank { randomPassphrase() }
        val wifi6 = caps["wifi_6"] == true
        val wifi5g = caps["wifi_5ghz"] == true
        val wifi6g = caps["wifi_6ghz"] == true
        val resolvedFreq = if (reqFreqMhz > 0) reqFreqMhz else channelToFreq(reqChannel)
        val priv = activePrivilegeMode("root_feature_direct_link", "shizuku_feature_direct_link")
        var lastErr = ""

        if (priv != "standard") {
            val attempts = mutableListOf<Pair<String, String>>()
            val widths = if (reqBwMhz in listOf(20, 40, 80, 160, 320)) {
                listOf(reqBwMhz, 80, 40).distinct()
            } else {
                listOf(160, 80)
            }
            if (resolvedFreq > 0) {
                val bFlag = when {
                    resolvedFreq > 5925 -> 6
                    resolvedFreq >= 5000 -> 5
                    else -> 2
                }
                val bLabel = bandForFreq(resolvedFreq).ifBlank { "5 GHz" }
                for (w in widths) {
                    if (bFlag == 2 && w > 40) continue
                    // Note: `-f <freq>` MUST be the last option on `cmd wifi start-lohs`.
                    attempts.add(bLabel to "cmd wifi start-lohs $ssid wpa2 $pass -b $bFlag -w $w -f $resolvedFreq")
                }
            } else if (bandPref == "6ghz" && wifi6g) {
                for (w in widths) {
                    attempts.add("6 GHz" to "cmd wifi start-lohs $ssid wpa2 $pass -b 6 -w $w")
                }
            }
            if (wifi5g && bandPref != "2ghz") {
                val best5gFreq = preferredAuto5GhzFreqs(2).firstOrNull()
                if (resolvedFreq <= 0 && best5gFreq != null) {
                    for (w in widths) {
                        attempts.add("5 GHz" to "cmd wifi start-lohs $ssid wpa2 $pass -b 5 -w $w -f $best5gFreq")
                    }
                }
                for (w in widths) {
                    attempts.add("5 GHz" to "cmd wifi start-lohs $ssid wpa2 $pass -b 5 -w $w")
                }
            }
            attempts.add("2.4 GHz" to "cmd wifi start-lohs $ssid wpa2 $pass -b 2")

            var usedBand = "5 GHz"
            var freq = 0
            var bw = 80
            var startedByShell = false

            for ((label, cmd) in attempts) {
                val res = runPrivilegedShell(priv, cmd) ?: break
                if (res.first == 0 && (res.second.contains("SAP is enabled") || res.second.contains("Lohs onStarted"))) {
                    startedByShell = true
                    usedBand = label
                    Regex("frequency=\\s*(\\d+)").find(res.second)?.groupValues?.getOrNull(1)?.toIntOrNull()?.let { f ->
                        freq = f
                        usedBand = when {
                            f > 5925 -> "6 GHz"
                            f >= 5000 -> "5 GHz"
                            else -> "2.4 GHz"
                        }
                    }
                    Regex("bandwidth=\\s*(\\d+)").find(res.second)?.groupValues?.getOrNull(1)?.toIntOrNull()?.let { b ->
                        bw = when (b) { 3 -> 40; 4 -> 80; 5 -> 160; 6 -> 320; else -> 20 }
                    }
                    break
                }
                lastErr = res.second.ifBlank { res.third }
            }

            if (startedByShell) {
                val net = waitForInterface(listOf("ap", "swlan", "wlan1", "wlan2"))
                    ?: error("Hotspot started ($usedBand via $priv) but no IPv4 interface appeared")
                activeMode = "hotspot"
                activeIface = net.first
                activeIp = net.second
                activeCidr = net.third
                activeBand = usedBand
                activeFreqMhz = freq
                activeBandwidthMhz = bw
                val std = if (wifi6) "Wi-Fi 6 (802.11ax)" else "Wi-Fi 5"
                activeWifiStd = std
                activeSsid = ssid
                activePassphrase = pass
                activePrivilege = priv
                saveSessionPrefs("hotspot", net.first, net.second, net.third, ssid, pass, usedBand, freq, bw, std, priv)
                startDirectAgent(net.first, net.third, 8731)
                return mapOf(
                    "ok" to true,
                    "kind" to "hotspot",
                    "transport" to "lan",
                    "mode" to priv,
                    "interface" to net.first,
                    "ip" to net.second,
                    "cidr" to net.third,
                    "endpoint" to "${net.second}:8731",
                    "ssid" to ssid,
                    "passphrase" to pass,
                    "band" to usedBand,
                    "channel" to freqToChannel(freq),
                    "frequency_mhz" to freq,
                    "bandwidth_mhz" to bw,
                    "wifi_standard" to std,
                    "status" to "active"
                )
            }
        }

        // Standard non-root / non-Shizuku path: request Location / Nearby Wi-Fi permission cleanly first.
        if (!ensureWifiPermissions()) {
            error("Grant Location / Nearby Wi-Fi Devices permission to start Hotspot in Standard mode (or enable Shizuku/Root in Settings)")
        }
        var (lohs, stdErr) = startStandardLocalOnlyHotspot()
        if (lohs == null && (stdErr.contains("Incompatible") || stdErr.contains("No available") || stdErr.contains("busy", ignoreCase = true))) {
            try { Thread.sleep(600) } catch (_: Exception) {}
            val retry = startStandardLocalOnlyHotspot()
            lohs = retry.first
            if (retry.second.isNotBlank()) stdErr = retry.second
        }
        if (lohs == null) {
            val detail = listOf(stdErr, lastErr).firstOrNull { it.isNotBlank() } ?: "Hotspot denied by Android"
            error("Could not start Hotspot ($detail)")
        }
        val iface = lohs.first
        val ip = lohs.second
        val cidr = lohs.third
        val apSsid = lohs.fourth.first
        val apPass = lohs.fourth.second
        activeMode = "hotspot"
        activeIface = iface
        activeIp = ip
        activeCidr = cidr
        activeSsid = apSsid
        activePassphrase = apPass
        activeBand = if (wifi5g) "5 GHz / Auto" else "2.4 GHz"
        activeWifiStd = ""
        activePrivilege = "standard"
        saveSessionPrefs("hotspot", iface, ip, cidr, apSsid, apPass, activeBand.orEmpty(), 0, 0, "", "standard")
        startDirectAgent(iface, cidr, 8731)
        return mapOf(
            "ok" to true,
            "kind" to "hotspot",
            "transport" to "lan",
            "mode" to "standard",
            "interface" to iface,
            "ip" to ip,
            "cidr" to cidr,
            "endpoint" to "$ip:8731",
            "ssid" to apSsid,
            "passphrase" to apPass,
            "band" to activeBand,
            "wifi_standard" to activeWifiStd,
            "status" to "active"
        )
    }

    private fun startWifiDirect(
        bandPref: String,
        customSsid: String = "",
        customPass: String = "",
        reqFreqMhz: Int = 0,
        reqChannel: Int = 0
    ): Map<String, Any?> {
        restore(forget = false)
        val caps = capabilitiesMap()
        if (caps["wifi_direct"] != true) {
            error("Wi-Fi Direct is unsupported on this device")
        }
        val suffix = "%04x".format(SecureRandom().nextInt(0x10000))
        var ssid = customSsid.ifBlank { "DIRECT-DB-$suffix" }
        var pass = customPass.ifBlank { randomPassphrase() }
        val wifi6 = caps["wifi_6"] == true
        val wifi5g = caps["wifi_5ghz"] == true
        val resolvedFreq = if (reqFreqMhz > 0) reqFreqMhz else channelToFreq(reqChannel)
        val priv = activePrivilegeMode("root_feature_direct_link", "shizuku_feature_direct_link")

        var created = false
        var actualFreq = 0
        var lastErr = ""
        var usedMode = priv

        if (priv != "standard") {
            val freqs = when {
                resolvedFreq > 0 -> listOf(resolvedFreq, 5, 2).distinct()
                bandPref == "2ghz" -> listOf(2)
                wifi5g -> (preferredAuto5GhzFreqs(8).take(3) + listOf(5, 2)).distinct()
                else -> listOf(2)
            }
            var resetDone = false
            for (f in freqs) {
                var res = runPrivilegedShell(priv, "cmd wifip2p init; cmd wifip2p create-group-with-config $ssid $pass $f false") ?: break
                if (!resetDone && (res.first != 0 || res.second.contains("Exception") || res.second.contains("FAILED"))) {
                    if (res.second.contains("reason 2") || res.third.contains("reason 2")) {
                        resetDone = true
                        runPrivilegedShell(priv, "cmd wifi set-wifi-enabled disabled && sleep 2 && cmd wifi set-wifi-enabled enabled && sleep 4")
                        res = runPrivilegedShell(priv, "cmd wifip2p init; cmd wifip2p create-group-with-config $ssid $pass $f false") ?: break
                    }
                }
                if (res.first == 0 && !res.second.contains("Exception") && !res.second.contains("FAILED")) {
                    created = true
                    val info = runPrivilegedShell(priv, "cmd wifip2p get-group-info")
                    if (info != null) {
                        Regex("frequency:\\s*(\\d+)").find(info.second)?.groupValues?.getOrNull(1)?.toIntOrNull()?.let { actualFreq = it }
                    }
                    break
                }
                lastErr = (res.second + " " + res.third).trim()
            }
        }

        if (!created) {
            if (!ensureWifiPermissions()) {
                error("Grant Location / Nearby Wi-Fi Devices permission to start Wi-Fi Direct in Standard mode (or enable Shizuku/Root in Settings)")
            }
            val (stdOk, stdInfo) = startStandardP2pGroup(ssid, pass, wifi5g && bandPref != "2ghz", resolvedFreq)
            created = stdOk
            usedMode = "standard"
            if (!created) {
                val hint = listOf(stdInfo, lastErr).firstOrNull { it.isNotBlank() } ?: "Wi-Fi Direct unavailable"
                error("Could not start Wi-Fi Direct group ($hint)")
            }
        }

        val net = waitForInterface(listOf("p2p-"))
            ?: error("Wi-Fi Direct group formed ($usedMode) but no P2P IPv4 interface appeared")
        if (actualFreq == 0) {
            actualFreq = queryP2pGroupFrequency()
        }
        val band = when {
            actualFreq > 5925 -> "6 GHz"
            actualFreq >= 5000 -> "5 GHz"
            actualFreq in 2400..2500 -> "2.4 GHz"
            wifi5g && bandPref != "2ghz" -> "5 GHz"
            else -> "2.4 GHz"
        }
        val p2pBw = if (actualFreq >= 5000) 80 else 0
        activeMode = "wifi_direct"
        activeIface = net.first
        activeIp = net.second
        activeCidr = net.third
        activeFreqMhz = actualFreq
        activeBandwidthMhz = p2pBw
        activeBand = band
        activeWifiStd = ""
        activeSsid = ssid
        activePassphrase = pass
        activePrivilege = usedMode
        saveSessionPrefs("wifi_direct", net.first, net.second, net.third, ssid, pass, band, actualFreq, p2pBw, "", usedMode)
        startDirectAgent(net.first, net.third, 8731)
        return mapOf(
            "ok" to true,
            "kind" to "wifi_direct",
            "transport" to "lan",
            "mode" to usedMode,
            "interface" to net.first,
            "ip" to net.second,
            "cidr" to net.third,
            "endpoint" to "${net.second}:8731",
            "ssid" to ssid,
            "passphrase" to pass,
            "band" to band,
            "channel" to freqToChannel(actualFreq),
            "frequency_mhz" to actualFreq,
            "bandwidth_mhz" to p2pBw,
            "wifi_standard" to "",
            "status" to "active"
        )
    }

    private fun queryP2pGroupFrequency(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
        val mgr = context.getSystemService(WifiP2pManager::class.java) ?: return 0
        val ch = p2pChannel ?: mgr.initialize(context, Looper.getMainLooper(), null) ?: return 0
        val latch = CountDownLatch(1)
        var freq = 0
        try {
            mgr.requestGroupInfo(ch) { group ->
                if (group != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    freq = group.frequency
                }
                latch.countDown()
            }
            latch.await(1500, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {}
        return freq
    }

    private fun wifiStandardLabel(std: Int): String = when {
        Build.VERSION.SDK_INT >= 33 && std == ScanResult.WIFI_STANDARD_11BE -> "Wi-Fi 7 (802.11be)"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && std == ScanResult.WIFI_STANDARD_11AX -> "Wi-Fi 6 (802.11ax)"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && std == ScanResult.WIFI_STANDARD_11AC -> "Wi-Fi 5 (802.11ac)"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && std == ScanResult.WIFI_STANDARD_11N -> "Wi-Fi 4 (802.11n)"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && std == ScanResult.WIFI_STANDARD_LEGACY -> "Wi-Fi (Legacy)"
        else -> ""
    }

    private fun bandForFreq(freq: Int): String = when {
        freq > 5925 -> "6 GHz"
        freq >= 5000 -> "5 GHz"
        freq in 2400..2500 -> "2.4 GHz"
        else -> ""
    }

    fun linkDetails(iface: String = ""): Map<String, Any?> {
        if (iface.startsWith("p2p") || (iface.isEmpty() && activeMode == "wifi_direct")) {
            val f = if (activeFreqMhz > 0) activeFreqMhz else queryP2pGroupFrequency()
            val b = bandForFreq(f).ifBlank { activeBand.orEmpty() }
            return mapOf(
                "interface" to (iface.ifBlank { activeIface.orEmpty() }),
                "frequency_mhz" to f,
                "channel" to freqToChannel(f),
                "band" to b,
                "wifi_standard" to activeWifiStd.orEmpty(),
                "ssid" to activeSsid.orEmpty(),
            )
        }
        if (iface.startsWith("ap") || iface.startsWith("swlan") || (iface.isEmpty() && activeMode == "hotspot")) {
            return mapOf(
                "interface" to (iface.ifBlank { activeIface.orEmpty() }),
                "frequency_mhz" to activeFreqMhz,
                "channel" to freqToChannel(activeFreqMhz),
                "band" to activeBand.orEmpty(),
                "wifi_standard" to activeWifiStd.orEmpty(),
                "ssid" to activeSsid.orEmpty(),
            )
        }
        var freq = 0
        var stdLabel = ""
        var ssid = ""
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && cm != null) {
                for (n in cm.allNetworks) {
                    val caps = cm.getNetworkCapabilities(n) ?: continue
                    if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
                    val wi = caps.transportInfo as? android.net.wifi.WifiInfo ?: continue
                    freq = wi.frequency
                    stdLabel = wifiStandardLabel(wi.wifiStandard)
                    ssid = wi.ssid?.trim('"')?.takeIf { it != "<unknown ssid>" }.orEmpty()
                    if (freq > 0) break
                }
            }
            if (freq == 0 && wifi != null) {
                @Suppress("DEPRECATION")
                val wi = wifi.connectionInfo
                if (wi != null) {
                    freq = wi.frequency
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        stdLabel = wifiStandardLabel(wi.wifiStandard)
                    }
                    ssid = wi.ssid?.trim('"')?.takeIf { it != "<unknown ssid>" }.orEmpty()
                }
            }
        } catch (_: Exception) {}
        return mapOf(
            "interface" to iface.ifBlank { "wlan0" },
            "frequency_mhz" to freq,
            "channel" to freqToChannel(freq),
            "band" to bandForFreq(freq),
            "wifi_standard" to stdLabel,
            "ssid" to ssid,
        )
    }

    fun neighbors(iface: String): List<String> {
        val found = linkedSetOf<String>()
        fun parse(text: String) {
            for (line in text.lines()) {
                val fields = line.trim().split(Regex("\\s+"))
                if (fields.isEmpty()) continue
                val ip = fields[0]
                if (!ip.matches(Regex("\\d+\\.\\d+\\.\\d+\\.\\d+"))) continue
                val devIdx = fields.indexOf("dev")
                if (devIdx >= 0 && devIdx + 1 < fields.size && fields[devIdx + 1] != iface) continue
                found.add(ip)
            }
        }
        try {
            val p = ProcessBuilder("ip", "-4", "neigh", "show", "dev", iface).start()
            val out = p.inputStream.bufferedReader().readText()
            p.waitFor(2, TimeUnit.SECONDS)
            parse(out)
        } catch (_: Exception) {}
        if (found.isEmpty()) {
            val priv = activePrivilegeMode("root_feature_neighbors", "shizuku_feature_direct_link")
            if (priv != "standard") {
                val res = runPrivilegedShell(priv, "ip -4 neigh show dev $iface")
                if (res != null && res.first == 0) parse(res.second)
            }
        }
        return found.toList()
    }

    private fun startStandardLocalOnlyHotspot(): Pair<Tuple4<String, String, String, Pair<String, String>>?, String> {
        val mgr = wifi ?: return null to "Wi-Fi service unavailable"
        val latch = CountDownLatch(1)
        var reservation: WifiManager.LocalOnlyHotspotReservation? = null
        var failReason = ""
        Handler(Looper.getMainLooper()).post {
            try {
                mgr.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                        reservation = r
                        latch.countDown()
                    }
                    override fun onFailed(reason: Int) {
                        failReason = when (reason) {
                            ERROR_NO_CHANNEL -> "No available Wi-Fi hotspot channel"
                            ERROR_GENERIC -> "Hotspot failed on device"
                            ERROR_INCOMPATIBLE_MODE -> "Incompatible Wi-Fi/hotspot mode active"
                            ERROR_TETHERING_DISALLOWED -> "Hotspot disallowed by policy"
                            else -> "Hotspot callback error $reason"
                        }
                        latch.countDown()
                    }
                }, Handler(Looper.getMainLooper()))
            } catch (se: SecurityException) {
                failReason = "Location or Nearby Wi-Fi permission missing"
                latch.countDown()
            } catch (e: Exception) {
                failReason = e.message ?: "LocalOnlyHotspot error"
                latch.countDown()
            }
        }
        latch.await(10, TimeUnit.SECONDS)
        val r = reservation ?: return null to failReason.ifBlank { "Timed out waiting for LocalOnlyHotspot" }
        lohsReservation = r
        var apSsid = ""
        var apPass = ""
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val softAp = r.softApConfiguration
                apSsid = softAp?.ssid?.trim('"').orEmpty()
                apPass = softAp?.passphrase?.trim('"').orEmpty()
            } catch (_: Exception) {}
        }
        if (apSsid.isBlank()) {
            @Suppress("DEPRECATION")
            val cfg = r.wifiConfiguration
            apSsid = cfg?.SSID?.trim('"').orEmpty()
            apPass = cfg?.preSharedKey?.trim('"').orEmpty()
        }
        val net = waitForInterface(listOf("ap", "swlan", "wlan1", "wlan2")) ?: run {
            r.close(); lohsReservation = null
            return null to "Hotspot started but IPv4 interface did not appear"
        }
        return Tuple4(net.first, net.second, net.third, apSsid to apPass) to ""
    }

    private fun startStandardP2pGroup(ssid: String, pass: String, prefer5g: Boolean, freqMhz: Int = 0): Pair<Boolean, String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return false to "Standard Wi-Fi Direct group configuration requires Android 10+"
        }
        val mgr = context.getSystemService(WifiP2pManager::class.java)
            ?: return false to "WifiP2pManager unavailable"
        val ch = mgr.initialize(context, Looper.getMainLooper(), null)
            ?: return false to "Could not initialize Wi-Fi P2P channel"
        p2pChannel = ch

        fun tryCreate(cfg: WifiP2pConfig): Pair<Boolean, String> {
            val latch = CountDownLatch(1)
            var ok = false
            var failDetail = ""
            try {
                mgr.createGroup(ch, cfg, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() { ok = true; latch.countDown() }
                    override fun onFailure(reason: Int) {
                        failDetail = when (reason) {
                            WifiP2pManager.P2P_UNSUPPORTED -> "Wi-Fi Direct unsupported"
                            WifiP2pManager.BUSY -> "Wi-Fi Direct framework busy (disable hotspot/Wi-Fi Direct and retry)"
                            WifiP2pManager.ERROR -> "Wi-Fi Direct framework error"
                            else -> "Wi-Fi Direct failure code $reason"
                        }
                        latch.countDown()
                    }
                })
            } catch (_: SecurityException) {
                return false to "Missing NEARBY_WIFI_DEVICES or Location permission for Wi-Fi Direct"
            }
            latch.await(8, TimeUnit.SECONDS)
            return ok to failDetail
        }

        if (freqMhz > 0) {
            val freqCfg = WifiP2pConfig.Builder()
                .setNetworkName(ssid)
                .setPassphrase(pass)
                .setGroupOperatingFrequency(freqMhz)
                .build()
            val res = tryCreate(freqCfg)
            if (res.first) return res
        }

        val band = if (prefer5g) WifiP2pConfig.GROUP_OWNER_BAND_5GHZ else WifiP2pConfig.GROUP_OWNER_BAND_2GHZ
        val cfg = WifiP2pConfig.Builder()
            .setNetworkName(ssid)
            .setPassphrase(pass)
            .setGroupOperatingBand(band)
            .build()
        var (ok, failDetail) = tryCreate(cfg)
        if (!ok && prefer5g) {
            // Retry auto band if driver rejects explicit 5 GHz GO config without root.
            val autoCfg = WifiP2pConfig.Builder()
                .setNetworkName(ssid)
                .setPassphrase(pass)
                .setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_AUTO)
                .build()
            val res = tryCreate(autoCfg)
            ok = res.first
            if (!ok) failDetail = res.second
        }
        return ok to failDetail
    }

    private fun interfaceIPv4(name: String): Triple<String, String, String>? {
        return try {
            val iface = NetworkInterface.getByName(name) ?: return null
            if (!iface.isUp || iface.isLoopback) return null
            val address = iface.interfaceAddresses.firstOrNull {
                it.address is Inet4Address && it.address.isSiteLocalAddress
            } ?: return null
            val ip = address.address.hostAddress ?: return null
            Triple(name, ip, "$ip/${address.networkPrefixLength}")
        } catch (_: Exception) {
            null
        }
    }

    private fun waitForInterface(prefixes: List<String>): Triple<String, String, String>? {
        val deadline = System.currentTimeMillis() + 6500L
        while (System.currentTimeMillis() < deadline) {
            try {
                val ifaces = NetworkInterface.getNetworkInterfaces()
                while (ifaces != null && ifaces.hasMoreElements()) {
                    val iface = ifaces.nextElement()
                    if (!iface.isUp || iface.isLoopback) continue
                    val name = iface.name ?: continue
                    if (prefixes.none { name.startsWith(it) }) continue
                    for (la in iface.interfaceAddresses) {
                        val addr = la.address
                        if (addr is Inet4Address && addr.isSiteLocalAddress) {
                            val ip = addr.hostAddress ?: continue
                            return Triple(name, ip, "$ip/${la.networkPrefixLength}")
                        }
                    }
                }
            } catch (_: Exception) {}
            Thread.sleep(250)
        }
        return null
    }

    private fun runPrivilegedShell(mode: String, cmd: String, timeoutSeconds: Long = 20L): Triple<Int, String, String>? {
        return when (mode) {
            "root" -> runSu(cmd, timeoutSeconds)
            "shizuku" -> runShizuku(cmd, timeoutSeconds)
            else -> null
        }
    }

    private fun runShizuku(cmd: String, timeoutSeconds: Long = 20L): Triple<Int, String, String> {
        return try {
            val method = Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java
            ).apply { isAccessible = true }
            val p = method.invoke(null, arrayOf("sh", "-c", cmd), null, null) as Process
            var stdout = ""
            var stderr = ""
            val t1 = thread { stdout = try { p.inputStream.bufferedReader().readText() } catch (_: Exception) { "" } }
            val t2 = thread { stderr = try { p.errorStream.bufferedReader().readText() } catch (_: Exception) { "" } }
            val done = p.waitFor(timeoutSeconds, TimeUnit.SECONDS)
            if (!done) {
                p.destroyForcibly()
                t1.join(500); t2.join(500)
                return Triple(-1, stdout, "Shizuku command timed out")
            }
            t1.join(500); t2.join(500)
            Triple(p.exitValue(), stdout, stderr)
        } catch (e: Exception) {
            Triple(-1, "", e.cause?.message ?: e.message ?: "Shizuku execution failed")
        }
    }

    private fun runSu(cmd: String, timeoutSeconds: Long = 20L): Triple<Int, String, String> {
        return try {
            val p = ProcessBuilder("su", "-c", cmd).start()
            var stdout = ""
            var stderr = ""
            val t1 = thread { stdout = try { p.inputStream.bufferedReader().readText() } catch (_: Exception) { "" } }
            val t2 = thread { stderr = try { p.errorStream.bufferedReader().readText() } catch (_: Exception) { "" } }
            val done = p.waitFor(timeoutSeconds, TimeUnit.SECONDS)
            if (!done) {
                p.destroyForcibly()
                t1.join(500); t2.join(500)
                return Triple(-1, stdout, "Command timed out")
            }
            t1.join(500); t2.join(500)
            Triple(p.exitValue(), stdout, stderr)
        } catch (e: Exception) {
            Triple(-1, "", e.message ?: "su unavailable")
        }
    }

    private fun handleHttp(socket: Socket) {
        socket.use { s ->
            s.soTimeout = 30000
            val reader = BufferedReader(InputStreamReader(s.getInputStream()))
            val out = s.getOutputStream()
            fun writeJson(status: Int, body: String) {
                val payload = body.toByteArray(Charsets.UTF_8)
                val header = "HTTP/1.1 $status OK\r\nContent-Type: application/json\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n"
                out.write(header.toByteArray(Charsets.US_ASCII))
                out.write(payload)
                out.flush()
            }
            try {
                val reqLine = reader.readLine() ?: return
                val parts = reqLine.split(" ")
                val path = parts.getOrNull(1) ?: ""
                var len = 0
                var authTok = ""
                while (true) {
                    val h = reader.readLine() ?: break
                    if (h.isEmpty()) break
                    val idx = h.indexOf(':')
                    if (idx > 0) {
                        val k = h.substring(0, idx).trim().lowercase()
                        val v = h.substring(idx + 1).trim()
                        if (k == "content-length") len = v.toIntOrNull() ?: 0
                        if (k == "x-devicebridge-token") authTok = v
                    }
                }
                if (!MessageDigest.isEqual(authTok.toByteArray(), token.toByteArray())) {
                    writeJson(401, """{"ok":false,"message":"unauthorized"}""")
                    return
                }
                val buf = CharArray(len.coerceIn(0, 16384))
                var readTotal = 0
                while (readTotal < buf.size) {
                    val n = reader.read(buf, readTotal, buf.size - readTotal)
                    if (n <= 0) break
                    readTotal += n
                }
                val bodyStr = String(buf, 0, readTotal)
                val resMap = when (path) {
                    "/prepare" -> {
                        val json = if (bodyStr.isNotBlank()) JSONObject(bodyStr) else JSONObject()
                        prepare(
                            json.optString("kind"),
                            json.optString("band", "auto"),
                            json.optString("ssid", ""),
                            json.optString("passphrase", ""),
                            json.optInt("frequency_mhz", 0),
                            json.optInt("channel", 0),
                            json.optInt("bandwidth_mhz", 0)
                        )
                    }
                    "/active" -> activeSessionMap()
                    "/restore" -> restore()
                    else -> error("Unsupported endpoint")
                }
                writeJson(200, JSONObject(resMap).toString())
            } catch (e: Exception) {
                try {
                    writeJson(400, JSONObject(mapOf("ok" to false, "message" to (e.message ?: "failed"))).toString())
                } catch (_: Exception) {}
            }
        }
    }

    private fun randomPassphrase(): String {
        val chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val rnd = SecureRandom()
        return buildString(16) { repeat(16) { append(chars[rnd.nextInt(chars.length)]) } }
    }

    fun close() {
        leaseFuture?.cancel(false)
        leaseScheduler.shutdownNow()
        closed = true
        try { server.close() } catch (_: Exception) {}
        workers.shutdownNow()
    }

    data class Tuple4<A, B, C, D>(val first: A, val second: B, val third: C, val fourth: D)
}
