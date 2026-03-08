package xyz.depollsoft.monkeyssh

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationCompat.BigTextStyle

/// Shows a persistent notification and holds a wake lock while an SSH
/// session is active while the app is backgrounded.
class SshConnectionService(private val context: Context) {

    data class ConnectionStatus(
        val connectionCount: Int,
        val connectedCount: Int,
        val primaryLabel: String,
        val primaryPreview: String?
    )

    companion object {
        const val CHANNEL_ID = "ssh_connection"
        const val NOTIFICATION_ID = 1
    }

    private var latestStatus: ConnectionStatus? = null
    private var isForeground = true
    private var wakeLock: PowerManager.WakeLock? = null

    init {
        createNotificationChannel()
    }

    /// Update the latest connection status and refresh the notification state.
    fun updateStatus(status: ConnectionStatus) {
        latestStatus = status
        refreshPresentation()
    }

    /// Update whether the app is currently in the foreground.
    fun setForegroundState(isForeground: Boolean) {
        this.isForeground = isForeground
        refreshPresentation()
    }

    /// Clear any active background keepalive UI and wake lock.
    fun stop() {
        latestStatus = null
        hidePresentation()
    }

    private fun refreshPresentation() {
        val status = latestStatus
        if (status == null || status.connectionCount <= 0 || isForeground) {
            hidePresentation()
            return
        }

        val tapIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val tapPendingIntent = if (tapIntent != null) {
            PendingIntent.getActivity(
                context, 0, tapIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null

        val title = if (status.connectionCount == 1) {
            "1 active SSH connection"
        } else {
            "${status.connectionCount} active SSH connections"
        }
        val summary = if (status.connectionCount == 1) {
            status.primaryLabel
        } else {
            "${status.primaryLabel} + ${status.connectionCount - 1} more"
        }
        val previewText = status.primaryPreview
            ?.replace('\n', ' ')
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "Keeping SSH connections alive in the background"

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(summary)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(tapPendingIntent)
            .setSubText("${
                if (status.connectedCount == status.connectionCount) {
                    "All sessions connected"
                } else {
                    "${status.connectedCount}/${status.connectionCount} connected"
                }
            }")
            .setStyle(
                BigTextStyle()
                    .bigText(previewText)
                    .setSummaryText(summary)
            )
            .build()

        val manager = context.getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification)

        // Acquire a partial wake lock to keep the CPU running for SSH keepalives.
        if (wakeLock?.isHeld != true) {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "monkeyssh:ssh_background"
            ).apply { acquire(24 * 60 * 60 * 1000L) }
        }
    }

    private fun hidePresentation() {
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
            description = "Shows when SSH sessions stay alive in the background"
            setShowBadge(false)
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }
}
