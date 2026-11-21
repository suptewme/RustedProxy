package dev.rustedproxy.app

import android.content.Context
import android.os.Process as AndroidProcess
import java.io.DataOutputStream
import java.io.File

/**
 * Root-only helpers. Every command runs through `su -c` and returns real
 * stdout/stderr, so the UI can show what actually happened on the device.
 */
object RootHelper {

    private const val KILL_CHAIN = "RUSTED_KS"
    private const val DNS_CHAIN = "RUSTED_DNS"

    private val suPaths = listOf(
        "/system/bin/su",
        "/system/xbin/su",
        "/sbin/su",
        "/su/bin/su",
        "/debug_ramdisk/su",
        "/data/adb/magisk",
        "/data/adb/ksu",
    )

    private val managerPackages = mapOf(
        "com.topjohnwu.magisk" to "Magisk",
        "io.github.huskydg.magisk" to "Magisk Delta",
        "me.weishu.kernelsu" to "KernelSU",
        "com.kingroot.kinguser" to "KingRoot",
        "eu.chainfire.supersu" to "SuperSU",
        "com.koushikdutta.superuser" to "Superuser",
        "com.thirdparty.superuser" to "Superuser",
    )

    @Volatile
    private var granted: Boolean? = null

    data class ShellResult(val ok: Boolean, val output: String, val code: Int)

    private fun waitFor(process: Process, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            try {
                process.exitValue()
                return true
            } catch (_: IllegalThreadStateException) {
            }
            try {
                Thread.sleep(25)
            } catch (_: InterruptedException) {
                return false
            }
        }
        return false
    }

    /** Passive probe: never triggers a root prompt. */
    fun available(context: Context): Boolean {
        if (suPaths.any { File(it).exists() }) return true
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("which", "su"))
            val finished = waitFor(p, 1500)
            val found = finished && p.exitValue() == 0 &&
                p.inputStream.bufferedReader().readText().trim().startsWith("/")
            if (!finished) p.destroy()
            found
        } catch (_: Throwable) {
            false
        }
    }

    fun manager(context: Context): String {
        for ((pkg, name) in managerPackages) {
            try {
                context.packageManager.getPackageInfo(pkg, 0)
                return name
            } catch (_: Throwable) {
            }
        }
        return if (File("/data/adb/magisk").exists()) "Magisk" else ""
    }

    fun status(context: Context): Map<String, Any> {
        val hasSu = available(context)
        val manager = manager(context)
        val selinux = try {
            val p = Runtime.getRuntime().exec(arrayOf("getenforce"))
            val out = p.inputStream.bufferedReader().readText().trim()
            waitFor(p, 1000)
            out
        } catch (_: Throwable) {
            ""
        }
        return mapOf(
            "available" to hasSu,
            "granted" to (granted == true),
            "manager" to manager,
            "selinux" to selinux,
            "uid" to AndroidProcess.myUid(),
            "path" to suPaths.firstOrNull { File(it).exists() }.orEmpty(),
        )
    }

    /** Runs a shell script as root. Blocks, so always call off the UI thread. */
    fun run(script: String, timeoutSec: Long = 45): ShellResult {
        var process: Process? = null
        return try {
            val proc = ProcessBuilder("su", "-c", "(\n$script\n) 2>&1; echo __RP_EXIT__$?").start()
            process = proc
            val output = StringBuilder()
            val reader = Thread {
                try {
                    proc.inputStream.bufferedReader().useLines { lines ->
                        lines.forEach { line ->
                            synchronized(output) { output.append(line).append('\n') }
                        }
                    }
                } catch (_: Throwable) {
                }
            }
            reader.start()
            DataOutputStream(proc.outputStream).use { it.flush() }
            val finished = waitFor(proc, timeoutSec * 1000)
            if (!finished) {
                proc.destroy()
                reader.join(400)
                granted = false
                return ShellResult(false, "su: превышено время ожидания", -1)
            }
            reader.join(800)
            val raw = synchronized(output) { output.toString().trim() }
            val marker = raw.lastIndexOf("__RP_EXIT__")
            val code = if (marker >= 0) raw.substring(marker + 11).trim().toIntOrNull() ?: -1 else -1
            val text = if (marker >= 0) raw.substring(0, marker).trim() else raw
            granted = code == 0
            ShellResult(code == 0, text, code)
        } catch (t: Throwable) {
            granted = false
            ShellResult(false, t.message ?: "root недоступен", -1)
        } finally {
            try {
                process?.destroy()
            } catch (_: Throwable) {
            }
        }
    }

    fun applyTuning(enabled: Boolean): Map<String, Any> {
        val script = if (enabled) {
            """
            TCP_CC=${'$'}(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
            case "${'$'}TCP_CC" in *bbr*) echo bbr > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null ;; esac
            echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null
            echo 26214400 > /proc/sys/net/core/rmem_max 2>/dev/null
            echo 26214400 > /proc/sys/net/core/wmem_max 2>/dev/null
            echo "4096 87380 26214400" > /proc/sys/net/ipv4/tcp_rmem 2>/dev/null
            echo "4096 65536 26214400" > /proc/sys/net/ipv4/tcp_wmem 2>/dev/null
            echo 3 > /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null
            echo 16384 > /proc/sys/net/ipv4/tcp_notsent_lowat 2>/dev/null
            echo "cc=${'$'}(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
            echo "qdisc=${'$'}(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
            echo "rmem=${'$'}(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
            """.trimIndent()
        } else {
            """
            echo cubic > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
            echo "cc=${'$'}(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
            """.trimIndent()
        }
        val r = run(script)
        return mapOf(
            "ok" to r.ok,
            "enabled" to enabled,
            "output" to r.output,
            "code" to r.code,
        )
    }

    fun setKillSwitch(enabled: Boolean, uid: Int): Map<String, Any> {
        val script = if (enabled) {
            """
            iptables -w -N $KILL_CHAIN 2>/dev/null
            iptables -w -F $KILL_CHAIN 2>/dev/null
            iptables -w -A $KILL_CHAIN -m owner --uid-owner $uid -j RETURN
            iptables -w -A $KILL_CHAIN -o lo -j RETURN
            iptables -w -A $KILL_CHAIN -d 127.0.0.0/8 -j RETURN
            iptables -w -A $KILL_CHAIN -j REJECT
            iptables -w -C OUTPUT -j $KILL_CHAIN 2>/dev/null || iptables -w -I OUTPUT 1 -j $KILL_CHAIN
            if command -v ip6tables >/dev/null 2>&1; then
              ip6tables -w -N $KILL_CHAIN 2>/dev/null
              ip6tables -w -F $KILL_CHAIN 2>/dev/null
              ip6tables -w -A $KILL_CHAIN -m owner --uid-owner $uid -j RETURN
              ip6tables -w -A $KILL_CHAIN -o lo -j RETURN
              ip6tables -w -A $KILL_CHAIN -d ::1/128 -j RETURN
              ip6tables -w -A $KILL_CHAIN -j REJECT
              ip6tables -w -C OUTPUT -j $KILL_CHAIN 2>/dev/null || ip6tables -w -I OUTPUT 1 -j $KILL_CHAIN
            fi
            iptables -w -S OUTPUT | grep -c $KILL_CHAIN
            """.trimIndent()
        } else {
            """
            while iptables -w -D OUTPUT -j $KILL_CHAIN 2>/dev/null; do :; done
            iptables -w -F $KILL_CHAIN 2>/dev/null
            iptables -w -X $KILL_CHAIN 2>/dev/null
            if command -v ip6tables >/dev/null 2>&1; then
              while ip6tables -w -D OUTPUT -j $KILL_CHAIN 2>/dev/null; do :; done
              ip6tables -w -F $KILL_CHAIN 2>/dev/null
              ip6tables -w -X $KILL_CHAIN 2>/dev/null
            fi
            echo removed
            """.trimIndent()
        }
        val r = run(script)
        return mapOf(
            "ok" to r.ok,
            "enabled" to enabled,
            "output" to r.output,
            "code" to r.code,
        )
    }

    fun setDnsRedirect(enabled: Boolean, server: String): Map<String, Any> {
        val safe = server.trim().substringBefore('/').substringBefore(':')
        val script = if (enabled) {
            require(safe.isNotEmpty()) { "empty dns" }
            """
            iptables -t nat -N $DNS_CHAIN 2>/dev/null
            iptables -t nat -F $DNS_CHAIN 2>/dev/null
            iptables -t nat -A $DNS_CHAIN -p udp --dport 53 -j DNAT --to-destination $safe:53
            iptables -t nat -A $DNS_CHAIN -p tcp --dport 53 -j DNAT --to-destination $safe:53
            iptables -t nat -C OUTPUT -j $DNS_CHAIN 2>/dev/null || iptables -t nat -I OUTPUT 1 -j $DNS_CHAIN
            iptables -t nat -S OUTPUT | grep -c $DNS_CHAIN
            """.trimIndent()
        } else {
            """
            while iptables -t nat -D OUTPUT -j $DNS_CHAIN 2>/dev/null; do :; done
            iptables -t nat -F $DNS_CHAIN 2>/dev/null
            iptables -t nat -X $DNS_CHAIN 2>/dev/null
            echo removed
            """.trimIndent()
        }
        val r = run(script)
        return mapOf(
            "ok" to r.ok,
            "enabled" to enabled,
            "server" to safe,
            "output" to r.output,
            "code" to r.code,
        )
    }

    fun clearDns(): Map<String, Any> {
        val r = run(
            """
            ndc resolver flushdefaultif 2>/dev/null
            ndc resolver flushnet 0 2>/dev/null
            ip -s neigh flush all 2>/dev/null
            echo flushed
            """.trimIndent()
        )
        return mapOf("ok" to r.ok, "output" to r.output, "code" to r.code)
    }

    fun check(): Map<String, Any> {
        val r = run("id -u")
        return mapOf(
            "ok" to (r.output.trim() == "0"),
            "output" to if (r.output.trim() == "0") "uid=0 (root)" else r.output,
            "code" to r.code,
        )
    }

    fun setAlwaysOn(enabled: Boolean): Map<String, Any> {
        val pkg = "dev.rustedproxy.app"
        val script = if (enabled) {
            """
            settings put secure always_on_vpn_app $pkg
            settings put secure always_on_vpn_lockdown 0
            settings get secure always_on_vpn_app
            """.trimIndent()
        } else {
            """
            settings delete secure always_on_vpn_app 2>/dev/null
            settings put secure always_on_vpn_lockdown 0
            echo disabled
            """.trimIndent()
        }
        val r = run(script)
        return mapOf("ok" to r.ok, "enabled" to enabled, "output" to r.output, "code" to r.code)
    }
}
