package dev.rustedproxy.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Restores the tunnel after a reboot or an app update when the user enabled
 * autostart in settings.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }
        val prefs = context.getSharedPreferences(RustedVpnService.PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("autostart", false)) return
        val config = prefs.getString("last_config", null)
        if (config.isNullOrBlank()) return
        if (RustedVpnService.running) return
        val service = Intent(context, RustedVpnService::class.java).apply {
            this.action = RustedVpnService.ACTION_START
            putExtra(RustedVpnService.EXTRA_CONFIG, config)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        } catch (_: Throwable) {
        }
    }
}
