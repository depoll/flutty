package xyz.depollsoft.monkeyssh

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
        private const val MAX_CLIPBOARD_CONTENT_URI_BYTES = 512 * 1024
        private const val MONKEYSSH_TRANSFER_MIME_TYPE = "application/x-monkeyssh-transfer"
        private const val MONKEYSSH_TRANSFER_EXTENSION = ".monkeysshx"
    }

    private val channel = "xyz.depollsoft.monkeyssh/ssh_service"
    private val clipboardChannel = "xyz.depollsoft.monkeyssh/clipboard_content"
    private val transferChannel = "xyz.depollsoft.monkeyssh/transfer"
    private val maxTransferPayloadBytes = 10 * 1024 * 1024
    private var clipboardMethodChannel: MethodChannel? = null
    private var transferMethodChannel: MethodChannel? = null
    private var pendingTransferPayload: String? = null
    private var hasRequestedNotificationPermission = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleTransferIntent(intent)
    }

    override fun getInitialRoute(): String? {
        if (isTransferIntent(intent)) {
            return "/"
        }
        return super.getInitialRoute()
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

        clipboardMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            clipboardChannel,
        )
        clipboardMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "readContentUri" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString.isNullOrBlank()) {
                        result.error("invalid_uri", "Clipboard URI was missing", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(readClipboardContentUri(Uri.parse(uriString)))
                    } catch (error: Exception) {
                        result.error(
                            "clipboard_read_failed",
                            error.message ?: "Failed to read clipboard URI",
                            null,
                        )
                    }
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
    }

    override fun onDestroy() {
        clipboardMethodChannel?.setMethodCallHandler(null)
        clipboardMethodChannel = null
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
        if (!isTransferIntent(intent)) {
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

    private fun isTransferIntent(intent: Intent?): Boolean {
        if (intent?.action != Intent.ACTION_VIEW) {
            return false
        }
        val sourceUri = intent.data ?: return false
        val hasSupportedScheme = when (sourceUri.scheme) {
            "content", "file" -> true
            else -> false
        }
        if (!hasSupportedScheme) {
            return false
        }
        val mimeType = intent.type?.lowercase()
        if (mimeType == MONKEYSSH_TRANSFER_MIME_TYPE) {
            return true
        }
        val lastPathSegment = sourceUri.lastPathSegment?.lowercase()
        return lastPathSegment?.endsWith(MONKEYSSH_TRANSFER_EXTENSION) == true
    }

    private fun readClipboardContentUri(uri: Uri): Map<String, Any> {
        val displayName = resolveDisplayName(uri) ?: "clipboard-file"
        val contentLength = resolveContentLength(uri)
        if (contentLength != null && contentLength > MAX_CLIPBOARD_CONTENT_URI_BYTES) {
            throw IllegalStateException(
                "Clipboard content exceeds ${MAX_CLIPBOARD_CONTENT_URI_BYTES / 1024} KB limit",
            )
        }
        val bytes = contentResolver.openInputStream(uri)?.use { stream ->
            val buffer = ByteArray(8192)
            val output = ByteArrayOutputStream()
            var bytesRead: Int
            var totalBytes = 0
            while (stream.read(buffer).also { bytesRead = it } != -1) {
                totalBytes += bytesRead
                if (totalBytes > MAX_CLIPBOARD_CONTENT_URI_BYTES) {
                    throw IllegalStateException(
                        "Clipboard content exceeds ${MAX_CLIPBOARD_CONTENT_URI_BYTES / 1024} KB limit",
                    )
                }
                output.write(buffer, 0, bytesRead)
            }
            output.toByteArray()
        } ?: throw IllegalStateException("Could not open clipboard URI")
        return mapOf(
            "name" to displayName,
            "bytes" to bytes,
        )
    }

    private fun resolveContentLength(uri: Uri): Long? {
        if (uri.scheme == "content") {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                val columnIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (columnIndex >= 0 && cursor.moveToFirst() && !cursor.isNull(columnIndex)) {
                    return cursor.getLong(columnIndex)
                }
            }
        }
        return null
    }

    private fun resolveDisplayName(uri: Uri): String? {
        if (uri.scheme == "content") {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                val columnIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (columnIndex >= 0 && cursor.moveToFirst()) {
                    return cursor.getString(columnIndex)
                }
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')
    }
}
