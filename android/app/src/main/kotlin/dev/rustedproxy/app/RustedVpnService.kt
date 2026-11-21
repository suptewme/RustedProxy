package dev.rustedproxy.app

import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import org.json.JSONObject

/**
 * Owns the Android TUN interface and hands its file descriptor to the Rust
 * core, which runs the userspace TCP/IP stack (tun2proxy) over the local
 * SOCKS5 engine.
 */
class RustedVpnService : VpnService() {

    companion object {
        const val ACTION_START = "dev.rustedproxy.app.START"
        const val ACTION_STOP = "dev.rustedproxy.app.STOP"
        const val ACTION_RESTART = "dev.rustedproxy.app.RESTART"
        const val EXTRA_CONFIG = "config"
        const val PREFS = "rustedproxy"
        const val NOTIFICATION_ID = 0x5250
        const val CHANNEL_ID = "rustedproxy_vpn"

        @Volatile
        var running: Boolean = false
            private set

        @Volatile
        var lastError: String = ""
            private set

        @Volatile
        var instance: RustedVpnService? = null
            private set

        fun markStopped() {
            running = false
        }

        /**
         * Crash-proof teardown used by MainActivity when the service cannot be
         * reached through a background start. Runs on the main looper.
         */
        fun requestStop() {
            val svc = instance
            if (svc == null) {
                running = false
                return
            }
            svc.mainHandler.post {
                try {
                    svc.teardown()
                } catch (_: Throwable) {
                }
                try {
                    svc.stopSelf()
                } catch (_: Throwable) {
                }
            }
            running = false
        }
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /** Public, self-contained teardown. */
    fun teardown() {
        stopTunnel()
    }

    private var tun: ParcelFileDescriptor? = null
    private var configJson: String? = null
    private var mtu = 1400
    @Volatile
    private var starting = false
    @Volatile
    private var canceled = false

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                canceled = true
                stopTunnel()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_RESTART -> {
                canceled = true
                stopTunnel(cleanupRoot = false)
                val cfg = intent.getStringExtra(EXTRA_CONFIG) ?: configJson
                if (cfg != null) launch(cfg)
                return START_STICKY
            }
            else -> {
                val cfg = intent?.getStringExtra(EXTRA_CONFIG) ?: loadConfig()
                if (cfg.isNullOrBlank()) {
                    lastError = "Конфигурация не найдена"
                    stopSelf()
                    return START_NOT_STICKY
                }
                launch(cfg)
            }
        }
        return START_STICKY
    }

    /**
     * Engine bootstrap performs a network round-trip (public IP lookup) and
     * must never run on the service's main thread.
     */
    private fun launch(config: String) {
        if (starting) return
        starting = true
        canceled = false
        Thread({
            try {
                startTunnel(config)
            } catch (t: Throwable) {
                lastError = t.message ?: t.toString()
                Log.e("RustedProxy", "vpn start error", t)
                stopTunnel()
                stopSelf()
            } finally {
                starting = false
            }
        }, "rustedproxy-vpn-start").start()
    }

    private fun loadConfig(): String? =
        getSharedPreferences(PREFS, MODE_PRIVATE).getString("last_config", null)

    private fun vpnOptions(json: String): JSONObject {
        return try {
            JSONObject(json).optJSONObject("vpn") ?: JSONObject()
        } catch (t: Throwable) {
            JSONObject()
        }
    }

    private fun startTunnel(json: String) {
        configJson = json
        if (running || canceled) return
        val options = vpnOptions(json)
        mtu = options.optInt("mtu", 1400).coerceIn(576, 1500)
        val ipv6 = options.optBoolean("ipv6", false)
        val dns = options.optString("dns", "1.1.1.1")
        val allowed = options.optJSONArray("allowed")
        val disallowed = options.optJSONArray("disallowed")

        try {
            val builder = Builder()
                .setSession("RustedProxy")
                .setMtu(mtu)
                .addAddress("10.111.222.1", 32)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(if (dns.isBlank()) "1.1.1.1" else dns)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }
            // Keep our own upstream sockets outside of the tunnel. When a
            // whitelist is active the app is not selected, so it is excluded
            // implicitly and mixing allow/disallow rules is illegal.
            var allowMode = false
            if (allowed != null && allowed.length() > 0) {
                for (i in 0 until allowed.length()) {
                    val pkg = allowed.optString(i)
                    if (pkg.isNotEmpty() && pkg != packageName) {
                        try {
                            builder.addAllowedApplication(pkg)
                            allowMode = true
                        } catch (_: Throwable) {
                        }
                    }
                }
            }
            if (!allowMode) {
                try {
                    builder.addDisallowedApplication(packageName)
                } catch (_: Throwable) {
                }
                if (disallowed != null) {
                    for (i in 0 until disallowed.length()) {
                        val pkg = disallowed.optString(i)
                        if (pkg.isNotEmpty() && pkg != packageName) {
                            try {
                                builder.addDisallowedApplication(pkg)
                            } catch (_: Throwable) {
                            }
                        }
                    }
                }
            }
            if (options.optBoolean("kill_switch", false)) {
                try {
                    builder.setBlocking(true)
                } catch (_: Throwable) {
                }
            }
            if (ipv6) {
                builder.addAddress("fd00:1:fd00:1::1", 128)
                builder.addRoute("::", 0)
            } else {
                // Still capture IPv6 so that it cannot leak around the tunnel;
                // the core rejects IPv6 upstreams while the toggle is off.
                builder.addAddress("fd00:1:fd00:1::1", 128)
                builder.addRoute("::", 0)
            }
            val descriptor = builder.establish()
                ?: run {
                    lastError = "Не удалось создать TUN-интерфейс"
                    stopSelf()
                    return
                }
            tun = descriptor
            startForegroundSafely()
            if (canceled) {
                stopTunnel()
                stopSelf()
                return
            }

            // The Flutter UI normally starts the engine before asking for the
            // tunnel; only bootstrap it when the service was launched on its
            // own (quick settings tile, boot receiver, system restore).
            val status = try {
                RustBridge.status()
            } catch (_: Throwable) {
                ""
            }
            if (!status.contains("\"running\":true")) {
                val engineResult = RustBridge.startEngine(json)
                if (engineResult.contains("\"error\"")) {
                    lastError = engineResult
                    Log.e("RustedProxy", "engine start failed: $engineResult")
                    stopTunnel()
                    stopSelf()
                    return
                }
            }
            if (canceled) {
                stopTunnel()
                stopSelf()
                return
            }
            val tunResult = RustBridge.startTun(descriptor.fd, mtu)
            if (tunResult.contains("\"error\"")) {
                lastError = tunResult
                Log.e("RustedProxy", "tun attach failed: $tunResult")
                stopTunnel()
                stopSelf()
                return
            }
            running = true
            lastError = ""
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putString("last_config", json)
                .putBoolean("vpn_running", true)
                .apply()
            Log.i("RustedProxy", "tunnel established (fd=${descriptor.fd}, mtu=$mtu)")
        } catch (t: Throwable) {
            lastError = t.message ?: t.toString()
            Log.e("RustedProxy", "vpn start error", t)
            stopTunnel()
            stopSelf()
        }
    }

    private fun startForegroundSafely() {
        val notification = Notifications.build(this, "Защищённое соединение активно", "RustedProxy")
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (t: Throwable) {
            Log.w("RustedProxy", "startForeground failed: ${t.message}")
        }
    }

    private fun stopTunnel(cleanupRoot: Boolean = true) {
        canceled = true
        running = false
        try {
            RustBridge.stopTun()
        } catch (_: Throwable) {
        }
        try {
            RustBridge.stopEngine()
        } catch (_: Throwable) {
        }
        try {
            tun?.close()
        } catch (_: Throwable) {
        }
        tun = null
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean("vpn_running", false)
            .apply()
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Throwable) {
        }
        if (cleanupRoot) cleanupRootRules()
        QsTileService.refresh(this)
    }

    /** Never leave an iptables kill switch behind after the tunnel stops. */
    private fun cleanupRootRules() {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        if (!prefs.getBoolean("root_kill_switch", false)) return
        prefs.edit().putBoolean("root_kill_switch", false).apply()
        Thread({
            try {
                RootHelper.setKillSwitch(false, android.os.Process.myUid())
            } catch (_: Throwable) {
            }
        }, "rustedproxy-root-cleanup").start()
    }

    override fun onRevoke() {
        stopTunnel()
        stopSelf()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopTunnel()
        instance = null
        super.onDestroy()
    }
}
