package xyz.depollsoft.monkeyssh

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "xyz.depollsoft.monkeyssh/ssh_service"
    private var sshService: SshConnectionService? = null

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
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == SshConnectionService.ACTION_STOP) {
            sshService?.stop()
        }
    }

    override fun onDestroy() {
        sshService?.stop()
        super.onDestroy()
    }
}
