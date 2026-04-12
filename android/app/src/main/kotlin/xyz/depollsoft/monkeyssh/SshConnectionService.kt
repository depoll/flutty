package xyz.depollsoft.monkeyssh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationCompat.BigTextStyle
import androidx.core.content.ContextCompat

/// Shows a persistent notification and holds a wake lock while an SSH
/// session is active while the app is backgrounded.
class SshConnectionService : Service() {

    data class ConnectionStatus(
        val connectionCount: Int,
        val connectedCount: Int
    )

    companion object {
        private const val TAG = "SshConnectionService"
        const val CHANNEL_ID = "ssh_connection"
        const val NOTIFICATION_ID = 1

        private const val ACTION_SYNC = "xyz.depollsoft.monkeyssh.action.SYNC"
        private const val ACTION_RESHOW_NOTIFICATION =
            "xyz.depollsoft.monkeyssh.action.RESHOW_NOTIFICATION"
        private const val EXTRA_CONNECTION_COUNT = "connectionCount"
        private const val EXTRA_CONNECTED_COUNT = "connectedCount"

        private var latestStatus: ConnectionStatus? = null
        private var isAppForeground = true

        fun updateStatus(context: Context, status: ConnectionStatus) {
            latestStatus = status
            syncServiceState(context)
        }

        fun setForegroundState(context: Context, isForeground: Boolean) {
            isAppForeground = isForeground
            syncServiceState(context)
        }

        fun refresh(context: Context) {
            syncServiceState(context)
        }

        fun hasActiveConnections(): Boolean = (latestStatus?.connectionCount ?: 0) > 0

        fun stop(context: Context) {
            latestStatus = null
            context.stopService(Intent(context, SshConnectionService::class.java))
        }

        private fun syncServiceState(context: Context) {
            val status = latestStatus
            if (status == null || status.connectionCount <= 0 || isAppForeground) {
                context.stopService(Intent(context, SshConnectionService::class.java))
                return
            }
            if (!hasNotificationPermission(context)) {
                context.stopService(Intent(context, SshConnectionService::class.java))
                return
            }

            val intent = Intent(context, SshConnectionService::class.java).apply {
                action = ACTION_SYNC
                putExtra(EXTRA_CONNECTION_COUNT, status.connectionCount)
                putExtra(EXTRA_CONNECTED_COUNT, status.connectedCount)
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (error: IllegalStateException) {
                Log.w(TAG, "Unable to start SSH foreground service", error)
                context.stopService(Intent(context, SshConnectionService::class.java))
            } catch (error: SecurityException) {
                Log.w(TAG, "SSH foreground service start denied", error)
                context.stopService(Intent(context, SshConnectionService::class.java))
            }
        }

        private fun hasNotificationPermission(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                return true
            }
            return ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.POST_NOTIFICATIONS
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    private var latestStatus: ConnectionStatus? = null
    private var isPresenting = false
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_SYNC) {
            latestStatus = extractStatus(intent) ?: latestStatus
        } else if (intent?.action == ACTION_RESHOW_NOTIFICATION) {
            Log.d(TAG, "Re-showing SSH foreground notification after dismissal")
        } else if (intent == null) {
            latestStatus = latestStatus ?: Companion.latestStatus
        }

        val status = latestStatus ?: Companion.latestStatus
        if (status != null && !isPresenting) {
            startForeground(NOTIFICATION_ID, buildNotification(status))
            isPresenting = true
        }

        refreshPresentation()
        return START_STICKY
    }

    override fun onDestroy() {
        hidePresentation()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun extractStatus(intent: Intent): ConnectionStatus? {
        val connectionCount = intent.getIntExtra(EXTRA_CONNECTION_COUNT, 0)
        if (connectionCount <= 0) {
            return null
        }
        return ConnectionStatus(
            connectionCount = connectionCount,
            connectedCount = intent.getIntExtra(EXTRA_CONNECTED_COUNT, 0)
        )
    }

    private fun refreshPresentation() {
        val status = latestStatus ?: Companion.latestStatus
        if (status == null || status.connectionCount <= 0 || Companion.isAppForeground) {
            hidePresentation()
            stopSelf()
            return
        }
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                this,
                android.Manifest.permission.POST_NOTIFICATIONS
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            hidePresentation()
            stopSelf()
            return
        }

        MonkeySshApplication.from(this).ensureSharedFlutterEngine()
        latestStatus = status
        val manager = getSystemService(NotificationManager::class.java)
        val notification = buildNotification(status)
        if (!isPresenting) {
            startForeground(NOTIFICATION_ID, notification)
            isPresenting = true
        } else {
            manager.notify(NOTIFICATION_ID, notification)
        }

        // Acquire a partial wake lock to keep the CPU running for SSH keepalives.
        if (wakeLock?.isHeld != true) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "monkeyssh:ssh_background"
            ).apply { acquire(24 * 60 * 60 * 1000L) }
        }
    }

    private fun buildNotification(status: ConnectionStatus): Notification {
        val tapIntent = packageManager.getLaunchIntentForPackage(packageName)
        val tapPendingIntent = if (tapIntent != null) {
            PendingIntent.getActivity(
                this, 0, tapIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null
        val reShowNotificationIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, SshConnectionService::class.java).apply {
                action = ACTION_RESHOW_NOTIFICATION
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val title = if (status.connectionCount == 1) {
            "1 active SSH connection"
        } else {
            "${status.connectionCount} active SSH connections"
        }
        val summary = if (status.connectedCount == status.connectionCount) {
            "All sessions connected"
        } else {
            "${status.connectedCount}/${status.connectionCount} connected"
        }
        val detailText = "Keeping SSH connections alive in the background"

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(summary)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(tapPendingIntent)
            .setDeleteIntent(reShowNotificationIntent)
            .setSubText(summary)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setStyle(
                BigTextStyle()
                    .bigText(detailText)
                    .setSummaryText(summary)
            )
            .build()

        notification.flags =
            notification.flags or Notification.FLAG_ONGOING_EVENT or Notification.FLAG_NO_CLEAR
        return notification
    }

    private fun hidePresentation() {
        val manager = getSystemService(NotificationManager::class.java)
        if (isPresenting) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            isPresenting = false
        }
        manager.cancel(NOTIFICATION_ID)

        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        wakeLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "SSH Connection",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows when SSH sessions stay alive in the background"
            setShowBadge(false)
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }
}
