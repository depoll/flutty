package xyz.depollsoft.monkeyssh

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/// Shows a persistent notification and holds a wake lock while an SSH
/// session is active. This is NOT a foreground service — it avoids the
/// Play Store foreground-service permission declaration requirement.
class SshConnectionService(private val context: Context) {

    companion object {
        const val CHANNEL_ID = "ssh_connection"
        const val NOTIFICATION_ID = 1
        const val ACTION_STOP = "xyz.depollsoft.monkeyssh.STOP_SERVICE"
    }

    private var wakeLock: PowerManager.WakeLock? = null

    init {
        createNotificationChannel()
    }

    /// Show a persistent notification and acquire a wake lock.
    fun start(hostName: String) {
        val stopIntent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_STOP
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val stopPendingIntent = PendingIntent.getActivity(
            context, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val tapIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val tapPendingIntent = if (tapIntent != null) {
            PendingIntent.getActivity(
                context, 0, tapIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle("Connected to $hostName")
            .setContentText("SSH session is active")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(tapPendingIntent)
            .addAction(android.R.drawable.ic_delete, "Disconnect", stopPendingIntent)
            .build()

        val manager = context.getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification)

        // Acquire a partial wake lock to keep the CPU running for SSH keepalives.
        if (wakeLock?.isHeld != true) {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "monkeyssh:ssh_background"
            ).apply { acquire() }
        }
    }

    /// Dismiss the notification and release the wake lock.
    fun stop() {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancel(NOTIFICATION_ID)

        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        wakeLock = null
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "SSH Connection",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows when an SSH session is active in the background"
            setShowBadge(false)
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }
}
