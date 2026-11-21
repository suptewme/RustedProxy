package dev.rustedproxy.app

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "dev.rustedproxy/app"
    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var channel: MethodChannel? = null
    private var pendingLink: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            try {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 0x5251)
            } catch (_: Throwable) {
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RustBridge.init(filesDir.absolutePath)
        pendingLink = extractLink(intent)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result -> handle(call, result) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = extractLink(intent) ?: return
        val ch = channel
        if (ch == null) {
            pendingLink = link
        } else {
            ch.invokeMethod("deepLink", link)
        }
    }

    private fun extractLink(intent: Intent?): String? {
        val data = intent?.data ?: return null
        val scheme = data.scheme?.lowercase() ?: return null
        if (scheme == "rustedproxy") {
            val direct = data.getQueryParameter("url")
                ?: data.getQueryParameter("link")
                ?: data.getQueryParameter("text")
            if (!direct.isNullOrBlank()) return direct
            val tail = data.toString()
                .substringAfter("rustedproxy://", "")
                .removePrefix("import")
                .removePrefix("/")
                .removePrefix("add/")
            return Uri.decode(tail).takeIf { it.isNotBlank() }
        }
        return data.toString()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareVpn" -> prepareVpn(result)
            "startVpn" -> {
                val config = call.argument<String>("config") ?: ""
                if (config.isBlank()) {
                    result.error("no_config", "Пустая конфигурация", null)
                    return
                }
                getSharedPreferences(RustedVpnService.PREFS, MODE_PRIVATE)
                    .edit().putString("last_config", config).apply()
                val intent = Intent(this, RustedVpnService::class.java).apply {
                    action = RustedVpnService.ACTION_START
                    putExtra(RustedVpnService.EXTRA_CONFIG, config)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
                result.success(true)
            }
            "stopVpn" -> {
                try {
                    val intent = Intent(this, RustedVpnService::class.java).apply {
                        action = RustedVpnService.ACTION_STOP
                    }
                    startService(intent)
                } catch (_: Throwable) {
                    // Background-service starts can be rejected on Android 12+.
                    // Fall back to an in-process teardown instead of crashing.
                    try {
                        RustedVpnService.requestStop()
                    } catch (_: Throwable) {
                    }
                }
                getSharedPreferences(RustedVpnService.PREFS, MODE_PRIVATE)
                    .edit().putBoolean("vpn_running", false).apply()
                result.success(false)
            }
            "vpnState" -> result.success(
                mapOf(
                    "running" to RustedVpnService.running,
                    "error" to RustedVpnService.lastError,
                    "prepared" to (VpnService.prepare(this) == null)
                )
            )
            "installedApps" -> result.success(installedApps())
            "saveAutostart" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                getSharedPreferences(RustedVpnService.PREFS, MODE_PRIVATE)
                    .edit().putBoolean("autostart", enabled).apply()
                result.success(true)
            }
            "autostart" -> result.success(
                getSharedPreferences(RustedVpnService.PREFS, MODE_PRIVATE)
                    .getBoolean("autostart", false)
            )
            "openVpnSettings" -> {
                try {
                    startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                } catch (_: Throwable) {
                }
                result.success(true)
            }
            "openAppSettings" -> {
                try {
                    startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName")
                        )
                    )
                } catch (_: Throwable) {
                }
                result.success(true)
            }
            "shareText" -> {
                val text = call.argument<String>("text") ?: ""
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, text)
                }
                startActivity(Intent.createChooser(send, "Поделиться"))
                result.success(true)
            }
            "appInfo" -> result.success(
                mapOf(
                    "package" to packageName,
                    "version" to versionName(),
                    "sdk" to Build.VERSION.SDK_INT,
                    "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
                    "abi" to Build.SUPPORTED_ABIS.firstOrNull().orEmpty()
                )
            )
            "networkType" -> result.success(networkType())
            "navMode" -> result.success(navMode())
            "permissions" -> result.success(permissions())
            "requestPermission" -> requestPermission(call, result)
            "requestBatteryOptimization" -> requestBattery(result)
            "openNotificationSettings" -> {
                try {
                    startActivity(
                        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    )
                } catch (_: Throwable) {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName")
                            )
                        )
                    } catch (_: Throwable) {
                    }
                }
                result.success(true)
            }
            "openBatterySettings" -> {
                try {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                } catch (_: Throwable) {
                }
                result.success(true)
            }
            "rootStatus" -> rootStatus(result)
            "rootCheck",
            "rootTuning",
            "rootKillSwitch",
            "rootDnsRedirect",
            "rootClearDns",
            "rootAlwaysOn" -> rootAction(call, result)
            "takeInitialLink" -> {
                val link = pendingLink
                pendingLink = null
                result.success(link)
            }
            else -> result.notImplemented()
        }
    }

    private fun versionName(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "1.0.0"
    } catch (_: Throwable) {
        "1.0.0"
    }

    private fun networkType(): String {
        return try {
            val cm = getSystemService(android.net.ConnectivityManager::class.java)
            val caps = cm?.activeNetwork?.let { cm.getNetworkCapabilities(it) } ?: return "none"
            when {
                caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "other"
            }
        } catch (_: Throwable) {
            "none"
        }
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        pendingVpnResult = result
        try {
            startActivityForResult(intent, VPN_REQUEST)
        } catch (t: Throwable) {
            pendingVpnResult = null
            result.error("vpn_prepare", t.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST) {
            val pending = pendingVpnResult
            pendingVpnResult = null
            pending?.success(resultCode == Activity.RESULT_OK)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST) {
            val pending = pendingPermissionResult
            pendingPermissionResult = null
            pending?.success(permissions())
        }
    }

    private fun permissions(): Map<String, Any> {
        val notifications = try {
            getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() ?: false
        } catch (_: Throwable) {
            false
        }
        val camera = checkSelfPermission(Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        val battery = try {
            getSystemService(PowerManager::class.java)
                ?.isIgnoringBatteryOptimizations(packageName) ?: false
        } catch (_: Throwable) {
            false
        }
        val vpn = try {
            VpnService.prepare(this) == null
        } catch (_: Throwable) {
            false
        }
        return mapOf(
            "notifications" to notifications,
            "camera" to camera,
            "battery" to battery,
            "vpn" to vpn,
        )
    }

    private fun requestPermission(call: MethodCall, result: MethodChannel.Result) {
        val type = call.argument<String>("type") ?: "all"
        if (type == "battery") {
            requestBattery(result)
            return
        }
        val wanted = ArrayList<String>()
        if (type == "camera" || type == "all") wanted.add(Manifest.permission.CAMERA)
        if ((type == "notifications" || type == "all") && Build.VERSION.SDK_INT >= 33) {
            wanted.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        val missing = wanted.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty() || Build.VERSION.SDK_INT < 23) {
            result.success(permissions())
            return
        }
        pendingPermissionResult = result
        try {
            requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
        } catch (t: Throwable) {
            pendingPermissionResult = null
            result.error("permissions", t.message, null)
        }
    }

    private fun requestBattery(result: MethodChannel.Result) {
        val powered = try {
            getSystemService(PowerManager::class.java)
                ?.isIgnoringBatteryOptimizations(packageName) ?: false
        } catch (_: Throwable) {
            false
        }
        if (powered) {
            result.success(permissions())
            return
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")
                )
            )
        } catch (_: Throwable) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Throwable) {
            }
        }
        result.success(true)
    }

    /** 0 = three buttons, 1 = two buttons, 2 = gesture navigation. */
    private fun navMode(): String {
        return try {
            val res = resources
            val id = res.getIdentifier("config_navBarInteractionMode", "integer", "android")
            if (id > 0) {
                when (res.getInteger(id)) {
                    0 -> "threeButton"
                    1 -> "twoButton"
                    2 -> "gesture"
                    else -> "unknown"
                }
            } else {
                "unknown"
            }
        } catch (_: Throwable) {
            "unknown"
        }
    }

    private fun rootStatus(result: MethodChannel.Result) {
        Thread {
            val status = try {
                RootHelper.status(this)
            } catch (t: Throwable) {
                mapOf(
                    "available" to false,
                    "granted" to false,
                    "manager" to "",
                    "selinux" to "",
                    "uid" to 0,
                    "path" to "",
                    "error" to (t.message ?: "error"),
                )
            }
            runOnUiThread { result.success(status) }
        }.start()
    }

    private fun rootAction(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: true
        val server = call.argument<String>("server") ?: "1.1.1.1"
        Thread {
            val out = try {
                when (call.method) {
                    "rootCheck" -> RootHelper.check()
                    "rootTuning" -> RootHelper.applyTuning(enabled)
                    "rootKillSwitch" -> RootHelper.setKillSwitch(enabled, Process.myUid())
                    "rootDnsRedirect" -> RootHelper.setDnsRedirect(enabled, server)
                    "rootClearDns" -> RootHelper.clearDns()
                    "rootAlwaysOn" -> RootHelper.setAlwaysOn(enabled)
                    else -> mapOf("ok" to false, "output" to "неизвестная операция")
                }
            } catch (t: Throwable) {
                mapOf("ok" to false, "output" to (t.message ?: "error"))
            }
            if (call.method == "rootKillSwitch" && out["ok"] == true) {
                getSharedPreferences(RustedVpnService.PREFS, MODE_PRIVATE)
                    .edit().putBoolean("root_kill_switch", enabled).apply()
            }
            runOnUiThread { result.success(out) }
        }.start()
    }

    private fun installedApps(): List<Map<String, Any>> {
        val pm = packageManager
        val out = ArrayList<Map<String, Any>>()
        val flags = if (Build.VERSION.SDK_INT >= 33) {
            PackageManager.PackageInfoFlags.of(0)
        } else {
            null
        }
        val packages = if (Build.VERSION.SDK_INT >= 33) {
            pm.getInstalledPackages(flags!!)
        } else {
            @Suppress("DEPRECATION")
            pm.getInstalledPackages(0)
        }
        for (info in packages) {
            val app = info.applicationInfo ?: continue
            if (app.packageName == packageName) continue
            val system = (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (system && app.packageName.startsWith("com.android.")) continue
            out.add(
                mapOf(
                    "package" to app.packageName,
                    "label" to pm.getApplicationLabel(app).toString(),
                    "system" to system
                )
            )
        }
        out.sortBy { (it["label"] as String).lowercase() }
        return out
    }

    companion object {
        private const val VPN_REQUEST = 0x5650
        private const val PERMISSION_REQUEST = 0x5651
    }
}
