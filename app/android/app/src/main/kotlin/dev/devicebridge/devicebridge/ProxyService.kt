package dev.devicebridge.devicebridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** The screen and proxy service share one node, socket and Tailscale identity. */
internal object AndroidTailnet {
    private var node: TailnetCoordinator? = null
    var screenChanged: (() -> Unit)? = null

    fun coordinator(context: Context): TailnetCoordinator {
        return node ?: TailnetCoordinator(context.applicationContext) {
            CoreRuntime.refreshPullNetwork()
            screenChanged?.invoke()
        }.also { node = it }
    }

    fun syncProxy(context: Context, coordinator: TailnetCoordinator, config: Map<String, Any>) {
        val intent = Intent(context, ProxyService::class.java)
        if (coordinator.enabled() && config["socks5_enabled"] == true) {
            try {
                context.startForegroundService(intent)
            } catch (e: IllegalStateException) {
                android.util.Log.w("DeviceBridge.Proxy", "Android deferred background proxy start", e)
            }
        } else {
            context.stopService(intent)
        }
    }
}

/** Preserves the user-enabled localhost proxy while other apps are visible. */
class ProxyService : Service() {
    private lateinit var node: TailnetCoordinator
    private lateinit var notification: Notification

    override fun onCreate() {
        super.onCreate()
        node = AndroidTailnet.coordinator(this)
        val channel = "local-proxy"
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(channel, "DeviceBridge proxy", NotificationManager.IMPORTANCE_LOW)
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, ProxyService::class.java).setAction("stop"),
            PendingIntent.FLAG_IMMUTABLE
        )
        val open = PendingIntent.getActivity(
            this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        notification = Notification.Builder(this, channel)
            .setContentTitle("DeviceBridge SOCKS5")
            .setContentText("Background proxy is enabled")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Stop proxy", stop).build())
            .build()
    }

    private fun showForegroundNotification() {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(3, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(3, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != "stop") showForegroundNotification()
        val prefs = getSharedPreferences("devicebridge-settings", MODE_PRIVATE)
        if (intent?.action == "stop") {
            prefs.edit().putBoolean("tsnet_socks5_enabled", false).apply()
            node.disableProxy()
        }
        if (!node.enabled() || !prefs.getBoolean("tsnet_socks5_enabled", false)) {
            stopSelf()
            return START_NOT_STICKY
        }
        node.proxyServiceActive(true)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        node.proxyServiceActive(false)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
