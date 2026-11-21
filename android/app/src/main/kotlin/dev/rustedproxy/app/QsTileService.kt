package dev.rustedproxy.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile that mirrors the VPN state and toggles the tunnel.
 */
class QsTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        val running = RustedVpnService.running
        if (running) {
            startService(
                Intent(this, RustedVpnService::class.java).setAction(RustedVpnService.ACTION_STOP)
            )
            RustedVpnService.markStopped()
            updateTile()
            return
        }
        val prefs = getSharedPreferences(RustedVpnService.PREFS, MODE_PRIVATE)
        val config = prefs.getString("last_config", null)
        if (config.isNullOrBlank()) {
            openApp()
            return
        }
        if (VpnServiceBridge.prepare(this) == null) {
            val intent = Intent(this, RustedVpnService::class.java).apply {
                action = RustedVpnService.ACTION_START
                putExtra(RustedVpnService.EXTRA_CONFIG, config)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            updateTile()
        } else {
            // Consent has to be granted from an activity.
            openApp()
        }
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(
                    android.app.PendingIntent.getActivity(
                        this,
                        0,
                        intent,
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                    )
                )
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        } catch (_: Throwable) {
            startActivity(intent)
        }
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val running = RustedVpnService.running
        tile.state = if (running) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "RustedProxy"
        if (Build.VERSION.SDK_INT >= 29) {
            tile.subtitle = if (running) "Защищено" else "Отключено"
        }
        try {
            tile.icon = Icon.createWithResource(this, R.drawable.ic_shield)
        } catch (_: Throwable) {
        }
        tile.updateTile()
    }

    companion object {
        fun refresh(context: Context) {
            try {
                requestListeningState(
                    context,
                    ComponentName(context, QsTileService::class.java)
                )
            } catch (_: Throwable) {
            }
        }
    }
}

/** Small helper so the tile can query consent without duplicating imports. */
private object VpnServiceBridge {
    fun prepare(context: Context): Intent? = android.net.VpnService.prepare(context)
}
