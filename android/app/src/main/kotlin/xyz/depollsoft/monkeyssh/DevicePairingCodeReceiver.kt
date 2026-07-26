package xyz.depollsoft.monkeyssh

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput

/**
 * Receives the Wireless debugging pairing code typed into the MonkeySSH
 * notification.
 *
 * Replying inline keeps the Android Settings pairing screen resumed, which is
 * required because Settings cancels pairing as soon as it pauses.
 */
class DevicePairingCodeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val results = RemoteInput.getResultsFromIntent(intent) ?: return
        val code = results
            .getCharSequence(DeviceDebugChannelHandler.PAIRING_CODE_RESULT_KEY)
            ?.toString()
            ?.trim()
            ?: return
        if (code.isEmpty()) {
            return
        }
        DeviceDebugChannelHandler.handleSubmittedPairingCode(
            context.applicationContext,
            code,
        )
    }
}
