package xyz.depollsoft.monkeyssh

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
                    "updateStatus" -> {
                        val connectionCount = call.argument<Int>("connectionCount") ?: 0
                        val connectedCount = call.argument<Int>("connectedCount") ?: 0
                        val primaryLabel = call.argument<String>("primaryLabel") ?: "SSH server"
                        val primaryPreview = call.argument<String>("primaryPreview")
                        sshService?.updateStatus(
                            SshConnectionService.ConnectionStatus(
                                connectionCount = connectionCount,
                                connectedCount = connectedCount,
                                primaryLabel = primaryLabel,
                                primaryPreview = primaryPreview
                            )
                        )
                        result.success(null)
                    }
                    "setForegroundState" -> {
                        val isForeground = call.argument<Boolean>("isForeground") ?: true
                        sshService?.setForegroundState(isForeground)
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

    override fun onDestroy() {
        sshService?.stop()
        super.onDestroy()
    }
}
