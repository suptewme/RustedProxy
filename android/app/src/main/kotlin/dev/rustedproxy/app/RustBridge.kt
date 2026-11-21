package dev.rustedproxy.app

/**
 * Thin JNI facade over the Rust networking core.
 *
 * The native library exposes the same entry points that the Dart FFI layer
 * uses, so both the UI process and the VPN service share one engine instance.
 */
object RustBridge {
    @Volatile
    private var loaded = false

    @Synchronized
    fun load(): Boolean {
        if (loaded) return true
        loaded = try {
            System.loadLibrary("rustedproxy_core")
            true
        } catch (t: Throwable) {
            false
        }
        return loaded
    }

    fun startEngine(configJson: String): String {
        if (!load()) return "{\"error\":\"native core unavailable\"}"
        return nativeStartEngine(configJson)
    }

    fun stopEngine(): String {
        if (!load()) return "{\"error\":\"native core unavailable\"}"
        return nativeStopEngine()
    }

    fun startTun(fd: Int, mtu: Int): String {
        if (!load()) return "{\"error\":\"native core unavailable\"}"
        return nativeStartTun(fd, mtu)
    }

    fun stopTun(): String {
        if (!load()) return "{\"ok\":true}"
        return nativeStopTun()
    }

    fun status(): String {
        if (!load()) return "{\"running\":false}"
        return nativeStatus()
    }

    fun init(dataDir: String): String {
        if (!load()) return "{\"error\":\"native core unavailable\"}"
        return nativeInit(dataDir)
    }

    private external fun nativeInit(dataDir: String): String
    private external fun nativeStartEngine(configJson: String): String
    private external fun nativeStopEngine(): String
    private external fun nativeStartTun(fd: Int, mtu: Int): String
    private external fun nativeStopTun(): String
    private external fun nativeStatus(): String
}
