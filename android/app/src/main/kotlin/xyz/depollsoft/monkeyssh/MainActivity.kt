package xyz.depollsoft.monkeyssh

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
    }

    private val channel = "xyz.depollsoft.monkeyssh/ssh_service"
    private val transferChannel = "xyz.depollsoft.monkeyssh/transfer"
    private val maxTransferPayloadBytes = 10 * 1024 * 1024
    private var transferMethodChannel: MethodChannel? = null
    private var pendingTransferPayload: String? = null
    private var hasRequestedNotificationPermission = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleTransferIntent(intent)
    }

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

        transferMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            transferChannel,
        )
        transferMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeIncomingTransferPayload" -> {
                    result.success(pendingTransferPayload)
                    pendingTransferPayload = null
                }
                else -> result.notImplemented()
            }
        }
        notifyIncomingTransferPayload()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleTransferIntent(intent)
        if (intent.action == SshConnectionService.ACTION_STOP) {
            SshConnectionService.stop(this)
        }
    }

    override fun onDestroy() {
        transferMethodChannel?.setMethodCallHandler(null)
        transferMethodChannel = null
        super.onDestroy()
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

    private fun handleTransferIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) {
            return
        }

        val sourceUri = intent.data ?: return
        try {
            pendingTransferPayload = contentResolver.openInputStream(sourceUri)?.use { stream ->
                val buffer = ByteArray(8192)
                val output = ByteArrayOutputStream()
                var bytesRead: Int
                var totalBytes = 0
                while (stream.read(buffer).also { bytesRead = it } != -1) {
                    totalBytes += bytesRead
                    if (totalBytes > maxTransferPayloadBytes) {
                        return@use null
                    }
                    output.write(buffer, 0, bytesRead)
                }
                output.toString(Charsets.UTF_8.name())
            }
            notifyIncomingTransferPayload()
        } catch (_: Exception) {
            pendingTransferPayload = null
        }
    }

    private fun notifyIncomingTransferPayload() {
        val payload = pendingTransferPayload ?: return
        transferMethodChannel?.invokeMethod("onIncomingTransferPayload", payload)
    }
}
