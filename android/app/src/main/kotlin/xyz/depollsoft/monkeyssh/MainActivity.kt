package xyz.depollsoft.monkeyssh

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
    }

    private val channel = "xyz.depollsoft.monkeyssh/ssh_service"
    private var hasRequestedNotificationPermission = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateStatus" -> {
                        val connectionCount = call.argument<Int>("connectionCount") ?: 0
                        val connectedCount = call.argument<Int>("connectedCount") ?: 0
                        SshConnectionService.updateStatus(
                            context = this,
                            status = SshConnectionService.ConnectionStatus(
                                connectionCount = connectionCount,
                                connectedCount = connectedCount
                            ),
                        )
                        result.success(null)
                    }
                    "setForegroundState" -> {
                        val isForeground = call.argument<Boolean>("isForeground") ?: true
                        if (!isForeground && SshConnectionService.hasActiveConnections()) {
                            ensureNotificationPermission()
                        }
                        SshConnectionService.setForegroundState(this, isForeground)
                        result.success(null)
                    }
                    "stopService" -> {
                        SshConnectionService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (
            requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE &&
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        ) {
            SshConnectionService.refresh(this)
        }
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        if (hasRequestedNotificationPermission) {
            return
        }
        hasRequestedNotificationPermission = true
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE
        )
    }
}
