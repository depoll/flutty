package xyz.depollsoft.monkeyssh

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "xyz.depollsoft.monkeyssh/ssh_service"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        val hostName = call.argument<String>("hostName") ?: "SSH server"
                        val intent = Intent(this, SshConnectionService::class.java).apply {
                            putExtra("hostName", hostName)
                        }
                        startForegroundService(intent)
                        result.success(null)
                    }
                    "stopService" -> {
                        val intent = Intent(this, SshConnectionService::class.java).apply {
                            action = SshConnectionService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
