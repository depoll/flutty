package xyz.depollsoft.monkeyssh

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "xyz.depollsoft.monkeyssh/ssh_service"
    private val transferChannel = "xyz.depollsoft.monkeyssh/transfer"
    private var sshService: SshConnectionService? = null
    private var transferMethodChannel: MethodChannel? = null
    private var pendingTransferPayload: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleTransferIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sshService = SshConnectionService(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        val hostName = call.argument<String>("hostName") ?: "SSH server"
                        sshService?.start(hostName)
                        result.success(null)
                    }
                    "stopService" -> {
                        sshService?.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        transferMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, transferChannel)
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
            sshService?.stop()
        }
    }

    override fun onDestroy() {
        sshService?.stop()
        transferMethodChannel?.setMethodCallHandler(null)
        transferMethodChannel = null
        super.onDestroy()
    }

    private fun handleTransferIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) {
            return
        }

        val sourceUri = intent.data ?: return
        try {
            contentResolver.openInputStream(sourceUri)?.bufferedReader(Charsets.UTF_8).use { reader ->
                pendingTransferPayload = reader?.readText()
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
