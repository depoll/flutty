package xyz.depollsoft.monkeyssh

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.KeyCharacterMap
import android.view.KeyEvent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
        private const val MAX_CLIPBOARD_CONTENT_URI_BYTES = 512 * 1024
        private const val MONKEYSSH_TRANSFER_MIME_TYPE = "application/x-monkeyssh-transfer"
        private const val MONKEYSSH_TRANSFER_EXTENSION = ".monkeysshx"
        private const val TERMINAL_IME_KEY_CHANNEL =
            "xyz.depollsoft.monkeyssh/terminal_ime_keys"
    }

    private val clipboardChannel = "xyz.depollsoft.monkeyssh/clipboard_content"
    private val transferChannel = "xyz.depollsoft.monkeyssh/transfer"
    private val maxTransferPayloadBytes = 10 * 1024 * 1024
    private var clipboardMethodChannel: MethodChannel? = null
    private var transferMethodChannel: MethodChannel? = null
    private var terminalImeKeyMethodChannel: MethodChannel? = null
    private var terminalImeKeyInterceptionEnabled = false
    private var pendingTransferPayload: String? = null
    private var hasRequestedNotificationPermission = false

    override fun onCreate(savedInstanceState: Bundle?) {
        MonkeySshApplication.from(this).ensureSharedFlutterEngine()
        super.onCreate(savedInstanceState)
        SshServiceChannelHandler.attachActivity(this)
        handleTransferIntent(intent)
    }

    override fun getCachedEngineId(): String {
        MonkeySshApplication.from(this).ensureSharedFlutterEngine()
        return MonkeySshApplication.SHARED_ENGINE_ID
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun getInitialRoute(): String? {
        if (isTransferIntent(intent)) {
            return "/"
        }
        return super.getInitialRoute()
    }

    override fun shouldHandleDeeplinking(): Boolean {
        if (isTransferIntent(intent)) {
            return false
        }
        return super.shouldHandleDeeplinking()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
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

        terminalImeKeyMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TERMINAL_IME_KEY_CHANNEL,
        )
        terminalImeKeyMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setInterceptionEnabled" -> {
                    terminalImeKeyInterceptionEnabled = call.arguments == true
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        terminalImeKeyMethodChannel?.invokeMethod(
            "getInterceptionEnabled",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    terminalImeKeyInterceptionEnabled = result == true
                }

                override fun error(
                    errorCode: String,
                    errorMessage: String?,
                    errorDetails: Any?,
                ) {
                    terminalImeKeyInterceptionEnabled = false
                }

                override fun notImplemented() {
                    terminalImeKeyInterceptionEnabled = false
                }
            },
        )

        notifyIncomingTransferPayload()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val channel = terminalImeKeyMethodChannel
        val key = terminalImeKeyName(event)
        val type = when {
            event.action == KeyEvent.ACTION_UP -> "release"
            event.action == KeyEvent.ACTION_DOWN && event.repeatCount > 0 -> "repeat"
            event.action == KeyEvent.ACTION_DOWN -> "press"
            else -> null
        }
        if (
            terminalImeKeyInterceptionEnabled &&
            channel != null &&
            key != null &&
            type != null
        ) {
            if (isVirtualKeyboardEvent(event)) {
                channel.invokeMethod(
                    "onVirtualKeyEvent",
                    mapOf("key" to key, "type" to type),
                )
                return true
            }
            channel.invokeMethod(
                "onPhysicalKeyEvent",
                mapOf("key" to key, "type" to type),
            )
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onResume() {
        super.onResume()
        // The "tap to return" prompt has done its job once the app is visible.
        DeviceDebugChannelHandler.hideReturnPrompt(applicationContext)
    }

    override fun onNewIntent(intent: Intent) {
        setIntent(intent)
        super.onNewIntent(intent)
        handleTransferIntent(intent)
    }

    override fun onDestroy() {
        SshServiceChannelHandler.detachActivity(this)
        clipboardMethodChannel?.setMethodCallHandler(null)
        clipboardMethodChannel = null
        transferMethodChannel?.setMethodCallHandler(null)
        transferMethodChannel = null
        terminalImeKeyInterceptionEnabled = false
        terminalImeKeyMethodChannel?.setMethodCallHandler(null)
        terminalImeKeyMethodChannel = null
        super.onDestroy()
    }

    private fun terminalImeKeyName(event: KeyEvent): String? = when (event.keyCode) {
        KeyEvent.KEYCODE_SHIFT_LEFT -> "shiftLeft"
        KeyEvent.KEYCODE_SHIFT_RIGHT -> "shiftRight"
        KeyEvent.KEYCODE_DEL -> "backspace"
        else -> null
    }

    private fun isVirtualKeyboardEvent(event: KeyEvent): Boolean =
        event.deviceId == KeyCharacterMap.VIRTUAL_KEYBOARD ||
            event.device?.isVirtual == true

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

    fun ensureNotificationPermission() {
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

        val transferIntent = intent ?: return
        val sourceUri = transferIntent.data ?: return
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
        val transferIntent = intent ?: return false
        if (transferIntent.action != Intent.ACTION_VIEW) {
            return false
        }
        val sourceUri = transferIntent.data ?: return false
        if (sourceUri.scheme != "content") {
            return false
        }
        val mimeType = transferIntent.type?.lowercase(Locale.ROOT)
        if (mimeType != MONKEYSSH_TRANSFER_MIME_TYPE) {
            return false
        }
        val lastPathSegment = sourceUri.lastPathSegment?.lowercase(Locale.ROOT)
        if (lastPathSegment?.endsWith(MONKEYSSH_TRANSFER_EXTENSION) == true) {
            return true
        }
        val displayName = runCatching { resolveContentDisplayName(sourceUri) }.getOrNull()
            ?.lowercase(Locale.ROOT)
        return displayName == null || displayName.endsWith(MONKEYSSH_TRANSFER_EXTENSION)
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
        val displayName = resolveContentDisplayName(uri)
        if (displayName != null) {
            return displayName
        }
        return uri.lastPathSegment?.substringAfterLast('/')
    }

    private fun resolveContentDisplayName(uri: Uri): String? {
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
        return null
    }
}
