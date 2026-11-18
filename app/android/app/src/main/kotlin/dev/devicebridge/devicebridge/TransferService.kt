package dev.devicebridge.devicebridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** User-started pulls only. No boot receiver, persistent service, or wake lock. */
class TransferService : Service() {
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("transfers", "DeviceBridge transfers", NotificationManager.IMPORTANCE_LOW))
        val cancel = PendingIntent.getService(this, 2, Intent(this, TransferService::class.java).setAction("cancel"), PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, "transfers").setContentTitle("DeviceBridge transfer")
            .setContentText("Downloading and verifying over your approved LAN")
            .setSmallIcon(android.R.drawable.stat_sys_download).setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Cancel", cancel).build()).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(1, notification)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "cancel") { CoreRuntime.cancel(); stopSelf() }
        return START_NOT_STICKY
    }
    override fun onTimeout(startId: Int, fgsType: Int) { CoreRuntime.cancel(); stopSelf() }
    override fun onBind(intent: Intent?): IBinder? = null
}
