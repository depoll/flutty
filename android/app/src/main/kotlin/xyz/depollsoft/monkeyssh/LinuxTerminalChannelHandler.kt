package xyz.depollsoft.monkeyssh

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Launches Google's AVF Linux Terminal app and related settings screens.
 *
 * Package/action names come from AOSP TerminalApp:
 * `com.android.virtualization.terminal` with action
 * `android.virtualization.VM_TERMINAL`.
 */
object LinuxTerminalChannelHandler {
    private const val CHANNEL = "xyz.depollsoft.monkeyssh/linux_terminal"
    private const val TAG = "LinuxTerminalChannel"

    private const val TERMINAL_PACKAGE = "com.android.virtualization.terminal"
    private const val TERMINAL_MAIN_ACTIVITY =
        "com.android.virtualization.terminal.MainActivity"
    private const val TERMINAL_PORT_FORWARD_ACTIVITY =
        "com.android.virtualization.terminal.SettingsPortForwardingActivity"
    private const val ACTION_VM_TERMINAL = "android.virtualization.VM_TERMINAL"

    private var methodChannel: MethodChannel? = null

    fun attachToEngine(flutterEngine: FlutterEngine, applicationContext: Context) {
        if (methodChannel != null) {
            return
        }

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                handleMethodCall(
                    call = call,
                    result = result,
                    applicationContext = applicationContext,
                )
            }
        }
    }

    private fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        applicationContext: Context,
    ) {
        when (call.method) {
            "getStatus" -> result.success(getStatus(applicationContext))
            "openTerminal" -> result.success(openTerminal(applicationContext))
            "openDeveloperOptions" ->
                result.success(openDeveloperOptions(applicationContext))
            "openPortForwardingSettings" ->
                result.success(openPortForwardingSettings(applicationContext))
            else -> result.notImplemented()
        }
    }

    private fun getStatus(context: Context): Map<String, Any?> {
        val packageManager = context.packageManager
        val installed = isPackageInstalled(packageManager, TERMINAL_PACKAGE)
        val enabled = if (!installed) {
            false
        } else {
            try {
                packageManager.getApplicationInfo(TERMINAL_PACKAGE, 0).enabled
            } catch (error: PackageManager.NameNotFoundException) {
                false
            }
        }
        val canLaunch = installed && enabled && resolveTerminalIntent(context) != null
        return mapOf(
            "installed" to installed,
            "enabled" to enabled,
            "canLaunch" to canLaunch,
            "packageName" to TERMINAL_PACKAGE,
        )
    }

    private fun openTerminal(context: Context): Boolean {
        val intent = resolveTerminalIntent(context) ?: return false
        return launchIntent(context, intent)
    }

    private fun openDeveloperOptions(context: Context): Boolean {
        val intent = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (launchIntent(context, intent)) {
            return true
        }
        val fallback = Intent(Settings.ACTION_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return launchIntent(context, fallback)
    }

    private fun openPortForwardingSettings(context: Context): Boolean {
        val intent = Intent().apply {
            setClassName(TERMINAL_PACKAGE, TERMINAL_PORT_FORWARD_ACTIVITY)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (launchIntent(context, intent)) {
            return true
        }
        // Fall back to launching the terminal app itself.
        return openTerminal(context)
    }

    private fun resolveTerminalIntent(context: Context): Intent? {
        val packageManager = context.packageManager

        val actionIntent = Intent(ACTION_VM_TERMINAL).apply {
            setPackage(TERMINAL_PACKAGE)
            addCategory(Intent.CATEGORY_DEFAULT)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (actionIntent.resolveActivity(packageManager) != null) {
            return actionIntent
        }

        val componentIntent = Intent().apply {
            setClassName(TERMINAL_PACKAGE, TERMINAL_MAIN_ACTIVITY)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (componentIntent.resolveActivity(packageManager) != null) {
            return componentIntent
        }

        return packageManager.getLaunchIntentForPackage(TERMINAL_PACKAGE)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    private fun isPackageInstalled(
        packageManager: PackageManager,
        packageName: String,
    ): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(0),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun launchIntent(context: Context, intent: Intent): Boolean {
        return try {
            context.startActivity(intent)
            true
        } catch (error: ActivityNotFoundException) {
            Log.w(TAG, "Activity not found for ${intent.action ?: intent.component}", error)
            false
        } catch (error: SecurityException) {
            Log.w(TAG, "Launch denied for ${intent.action ?: intent.component}", error)
            false
        } catch (error: RuntimeException) {
            Log.w(TAG, "Launch failed for ${intent.action ?: intent.component}", error)
            false
        }
    }
}
