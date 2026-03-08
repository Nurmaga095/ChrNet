package com.chrnet.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import go.Seq
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray
import org.json.JSONArray
import org.json.JSONObject

class XrayVpnService : VpnService() {

    companion object {
        const val NOTIFICATION_ID = 1001
        const val CHANNEL_ID = "chrnet_vpn_channel"
        const val ACTION_STOP = "com.chrnet.vpn.STOP"
        const val ACTION_RESTART = "com.chrnet.vpn.RESTART"
        private const val TAG = "XrayVpnService"
        private const val TUN_ESTABLISH_ATTEMPTS = 20
        private const val TUN_ESTABLISH_DELAY_MS = 500L
        private const val TAKEOVER_RETRIES = 2
        private const val TAKEOVER_RETRY_DELAY_MS = 1500L

        var eventSink: EventChannel.EventSink? = null
        var methodChannel: MethodChannel? = null
        var isVpnRunning = false

        fun postToFlutter(method: String, arg: Any? = null) {
            Handler(Looper.getMainLooper()).post {
                methodChannel?.invokeMethod(method, arg)
            }
        }
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var coreController: CoreController? = null
    @Volatile private var intentionallyStopped = false
    @Volatile private var activeSessionId = 0L
    private val restartHandler = Handler(Looper.getMainLooper())
    private var pendingRestartRunnable: Runnable? = null
    private var pendingTakeoverRunnable: Runnable? = null
    private var statsThread: Thread? = null

    // ─── Service lifecycle ────────────────────────────────────────────────────

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopVpn()
                return START_NOT_STICKY
            }
            ACTION_RESTART -> {
                val rawUri = intent.getStringExtra("config") ?: return START_NOT_STICKY
                val ruRouting = intent.getBooleanExtra("ruRouting", false)
                restartVpn(rawUri, ruRouting)
                return START_STICKY
            }
        }
        val rawUri = intent?.getStringExtra("config") ?: return START_NOT_STICKY
        val ruRouting = intent.getBooleanExtra("ruRouting", false)
        startVpn(rawUri, ruRouting)
        return START_STICKY
    }

    private fun startVpn(rawUri: String, ruRouting: Boolean, takeoverRetry: Int = 0) {
        val sessionId = ++activeSessionId
        intentionallyStopped = false
        createNotificationChannel()
        try {
            startForegroundCompat("Подключение...")
            // Initialize Go runtime and Xray environment
            Seq.setContext(applicationContext)
            Libv2ray.initCoreEnv(filesDir.absolutePath, "")

            // Create TUN interface first — Xray will read from this fd
            val tun = createTunInterface(
                maxAttempts = TUN_ESTABLISH_ATTEMPTS,
                delayMs = TUN_ESTABLISH_DELAY_MS
            ) ?: run {
                if (takeoverRetry < TAKEOVER_RETRIES) {
                    val nextAttempt = takeoverRetry + 1
                    Log.w(
                        TAG,
                        "TUN busy, scheduling takeover retry #$nextAttempt in ${TAKEOVER_RETRY_DELAY_MS}ms"
                    )
                    pendingTakeoverRunnable?.let { restartHandler.removeCallbacks(it) }
                    val runnable = Runnable {
                        pendingTakeoverRunnable = null
                        if (!intentionallyStopped) {
                            startVpn(rawUri, ruRouting, nextAttempt)
                        }
                    }
                    pendingTakeoverRunnable = runnable
                    restartHandler.postDelayed(runnable, TAKEOVER_RETRY_DELAY_MS)
                    return
                }
                notifyError(
                    "Не удалось занять VPN-интерфейс. " +
                        "Если включен Always-on VPN в другом приложении, отключите его и повторите."
                )
                return
            }
            vpnInterface = tun

            // Build Xray JSON config with tun inbound
            val config = buildXrayConfig(rawUri, ruRouting)

            // Create callback handler
            val callback = object : CoreCallbackHandler {
                override fun startup(): Long = 0
                override fun shutdown(): Long {
                    // Ignore stale callbacks from previous reconnect attempts.
                    if (!intentionallyStopped && sessionId == activeSessionId) {
                        Handler(Looper.getMainLooper()).post {
                            if (!intentionallyStopped && sessionId == activeSessionId) {
                                stopVpn()
                            }
                        }
                    }
                    return 0
                }
                override fun onEmitStatus(l: Long, s: String?): Long = 0
            }

            // Start Xray core with the TUN fd
            val controller = Libv2ray.newCoreController(callback)
            controller.startLoop(config, tun.fd)
            coreController = controller

            isVpnRunning = true
            updateNotification("ChrNet активен")
            notifyConnected()
            startStatsThread()
        } catch (e: Exception) {
            notifyError(e.message ?: "Ошибка запуска VPN")
        }
    }

    private fun restartVpn(rawUri: String, ruRouting: Boolean) {
        intentionallyStopped = true
        stopCore(notifyFlutter = false, stopService = false)
        intentionallyStopped = false
        pendingTakeoverRunnable?.let { restartHandler.removeCallbacks(it) }
        pendingTakeoverRunnable = null
        pendingRestartRunnable?.let { restartHandler.removeCallbacks(it) }
        val runnable = Runnable {
            pendingRestartRunnable = null
            startVpn(rawUri, ruRouting)
        }
        pendingRestartRunnable = runnable
        restartHandler.postDelayed(runnable, 250)
    }

    private fun startForegroundCompat(text: String) {
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    // Create Android TUN interface. Self-app excluded so Xray's outbound sockets
    // bypass the tunnel and connect directly (no routing loop).
    private fun createTunInterface(
        maxAttempts: Int = 6,
        delayMs: Long = 500,
    ): ParcelFileDescriptor? {
        var lastError: Throwable? = null
        repeat(maxAttempts) { attempt ->
            try {
                val tun = Builder()
                    .setSession("ChrNet")
                    .addAddress("10.0.0.1", 30)
                    .addDnsServer("1.1.1.1")
                    .addDnsServer("8.8.8.8")
                    .setMtu(1500)
                    .addRoute("0.0.0.0", 0)
                    .addDisallowedApplication(packageName)
                    .establish()
                if (tun != null) {
                    if (attempt > 0) {
                        Log.i(TAG, "TUN established on retry #$attempt")
                    }
                    return tun
                }
                lastError = IllegalStateException("Builder.establish() returned null")
            } catch (t: Throwable) {
                lastError = t
                Log.w(TAG, "TUN establish failed on attempt #$attempt: ${t.message}")
            }

            if (attempt < maxAttempts - 1) {
                try {
                    Thread.sleep(delayMs)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return null
                }
            }
        }
        Log.e(TAG, "Failed to establish TUN after $maxAttempts attempts", lastError)
        return null
    }

    private fun stopVpn() {
        intentionallyStopped = true
        pendingTakeoverRunnable?.let { restartHandler.removeCallbacks(it) }
        pendingTakeoverRunnable = null
        stopCore(notifyFlutter = true, stopService = true)
    }

    override fun onDestroy() {
        pendingRestartRunnable?.let { restartHandler.removeCallbacks(it) }
        pendingRestartRunnable = null
        pendingTakeoverRunnable?.let { restartHandler.removeCallbacks(it) }
        pendingTakeoverRunnable = null
        isVpnRunning = false
        stopStatsThread()
        if (!intentionallyStopped) {
            try { coreController?.stopLoop(); coreController = null } catch (_: Exception) {}
            closeTun()
        }
        super.onDestroy()
    }

    private fun stopCore(notifyFlutter: Boolean, stopService: Boolean) {
        isVpnRunning = false
        stopStatsThread()
        try { coreController?.stopLoop(); coreController = null } catch (_: Exception) {}
        closeTun()
        if (notifyFlutter) {
            notifyDisconnected()
        }
        if (stopService) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    // ─── Stats ────────────────────────────────────────────────────────────────

    private fun startStatsThread() {
        stopStatsThread()
        var totalDownload = 0L
        var totalUpload = 0L
        val downloadSpeedSamples = ArrayDeque<Long>()
        val uploadSpeedSamples = ArrayDeque<Long>()
        statsThread = Thread {
            // Drain any bytes accumulated during Xray startup before first report
            try {
                coreController?.queryStats("proxy", "downlink")
                coreController?.queryStats("proxy", "uplink")
            } catch (_: Exception) {}
            while (isVpnRunning) {
                try {
                    Thread.sleep(1000)
                    try {
                        // queryStats resets the counter after reading, so accumulate
                        val dl = coreController?.queryStats("proxy", "downlink") ?: 0L
                        val ul = coreController?.queryStats("proxy", "uplink") ?: 0L
                        totalDownload += dl
                        totalUpload += ul
                        val downSpeed = smoothSpeedSample(dl, downloadSpeedSamples)
                        val upSpeed = smoothSpeedSample(ul, uploadSpeedSamples)
                        val notificationText = buildSpeedNotificationText(downSpeed, upSpeed)
                        Handler(Looper.getMainLooper()).post {
                            updateNotification(notificationText)
                        }
                    } catch (_: Exception) {}
                    val dl = totalDownload; val ul = totalUpload
                    Handler(Looper.getMainLooper()).post {
                        eventSink?.success(mapOf("download" to dl, "upload" to ul))
                    }
                } catch (_: InterruptedException) { break }
            }
        }
        statsThread!!.start()
    }

    private fun stopStatsThread() { statsThread?.interrupt(); statsThread = null }
    private fun closeTun() { try { vpnInterface?.close(); vpnInterface = null } catch (_: Exception) {} }

    // ─── Xray JSON config builder ─────────────────────────────────────────────

    private fun buildXrayConfig(rawUri: String, ruRouting: Boolean): String {
        val config = JSONObject()
        config.put("stats", JSONObject())
        config.put("log", JSONObject().apply { put("loglevel", "warning") })
        config.put("policy", JSONObject().apply {
            put("levels", JSONObject().apply {
                put("8", JSONObject().apply {
                    put("handshake", 4); put("connIdle", 300)
                    put("uplinkOnly", 1); put("downlinkOnly", 1)
                })
            })
            put("system", JSONObject().apply {
                put("statsOutboundUplink", true)
                put("statsOutboundDownlink", true)
            })
        })
        config.put("dns", JSONObject().apply {
            put("servers", JSONArray().apply { put("1.1.1.1"); put("8.8.8.8") })
        })

        // TUN inbound — Xray reads packets from the fd set by startLoop()
        config.put("inbounds", JSONArray().apply {
            put(JSONObject().apply {
                put("tag", "tun"); put("port", 0); put("protocol", "tun")
                put("settings", JSONObject().apply {
                    put("name", "xray0"); put("MTU", 1500); put("userLevel", 8)
                })
                put("sniffing", JSONObject().apply {
                    put("enabled", true)
                    put("destOverride", JSONArray().apply { put("http"); put("tls") })
                })
            })
        })

        val outbounds = JSONArray()
        outbounds.put(buildOutbound(rawUri))
        outbounds.put(JSONObject().apply { put("tag", "direct"); put("protocol", "freedom") })
        outbounds.put(JSONObject().apply { put("tag", "block"); put("protocol", "blackhole") })
        config.put("outbounds", outbounds)

        config.put("routing", JSONObject().apply {
            put("domainStrategy", "IPIfNonMatch")
            put("rules", JSONArray().apply {
                put(JSONObject().apply {
                    put("type", "field"); put("outboundTag", "direct")
                    put("ip", JSONArray().apply {
                        put("10.0.0.0/8"); put("172.16.0.0/12"); put("192.168.0.0/16"); put("127.0.0.0/8")
                    })
                })
                if (ruRouting) {
                    put(JSONObject().apply {
                        put("type", "field")
                        put("outboundTag", "direct")
                        put("domain", JSONArray().apply { put("geosite:category-ru") })
                    })
                    put(JSONObject().apply {
                        put("type", "field")
                        put("outboundTag", "direct")
                        put("ip", JSONArray().apply { put("geoip:ru") })
                    })
                }
                put(JSONObject().apply {
                    put("type", "field")
                    put("inboundTag", JSONArray().apply { put("tun") })
                    put("outboundTag", "proxy")
                })
            })
        })
        return config.toString()
    }

    private fun buildOutbound(uri: String): JSONObject = when {
        uri.startsWith("vless://")  -> buildVless(uri)
        uri.startsWith("vmess://")  -> buildVmess(uri)
        uri.startsWith("trojan://") -> buildTrojan(uri)
        else -> throw IllegalArgumentException("Unsupported protocol")
    }

    private fun buildVless(uri: String): JSONObject {
        val s = uri.removePrefix("vless://")
        val hash = s.lastIndexOf('#'); val main = if (hash >= 0) s.substring(0, hash) else s
        val at = main.indexOf('@'); val uuid = main.substring(0, at); val hp = main.substring(at + 1)
        val q = hp.indexOf('?'); val hostPort = if (q >= 0) hp.substring(0, q) else hp
        val query = parseQuery(if (q >= 0) hp.substring(q + 1) else "")
        val (host, port) = splitHostPort(hostPort)
        val flow = query["flow"] ?: ""
        return JSONObject().apply {
            put("tag", "proxy"); put("protocol", "vless")
            put("settings", JSONObject().apply {
                put("vnext", JSONArray().apply {
                    put(JSONObject().apply {
                        put("address", host); put("port", port)
                        put("users", JSONArray().apply {
                            put(JSONObject().apply {
                                put("id", uuid); put("encryption", "none")
                                if (flow.isNotEmpty()) put("flow", flow)
                            })
                        })
                    })
                })
            })
            put("streamSettings", buildStream(query["type"] ?: "tcp", query["security"] ?: "none", query["sni"] ?: host, query))
        }
    }

    private fun buildVmess(uri: String): JSONObject {
        val json = JSONObject(android.util.Base64.decode(padBase64(uri.removePrefix("vmess://")), android.util.Base64.DEFAULT).toString(Charsets.UTF_8))
        val host = json.optString("add"); val port = json.optInt("port", 443)
        val tls = json.optString("tls", "none")
        return JSONObject().apply {
            put("tag", "proxy"); put("protocol", "vmess")
            put("settings", JSONObject().apply {
                put("vnext", JSONArray().apply {
                    put(JSONObject().apply {
                        put("address", host); put("port", port)
                        put("users", JSONArray().apply {
                            put(JSONObject().apply {
                                put("id", json.optString("id")); put("alterId", json.optInt("aid", 0)); put("security", "auto")
                            })
                        })
                    })
                })
            })
            put("streamSettings", buildStream(json.optString("net", "tcp"), if (tls == "tls") "tls" else "none", json.optString("sni", host), emptyMap()))
        }
    }

    private fun buildTrojan(uri: String): JSONObject {
        val s = uri.removePrefix("trojan://")
        val hash = s.lastIndexOf('#'); val main = if (hash >= 0) s.substring(0, hash) else s
        val at = main.indexOf('@'); val pwd = main.substring(0, at); val hp = main.substring(at + 1)
        val q = hp.indexOf('?'); val hostPort = if (q >= 0) hp.substring(0, q) else hp
        val query = parseQuery(if (q >= 0) hp.substring(q + 1) else "")
        val (host, port) = splitHostPort(hostPort)
        return JSONObject().apply {
            put("tag", "proxy"); put("protocol", "trojan")
            put("settings", JSONObject().apply {
                put("servers", JSONArray().apply {
                    put(JSONObject().apply { put("address", host); put("port", port); put("password", pwd) })
                })
            })
            put("streamSettings", buildStream("tcp", "tls", query["sni"] ?: host, query))
        }
    }

    private fun buildStream(network: String, security: String, sni: String, q: Map<String, String>): JSONObject {
        val transport = network.lowercase()
        return JSONObject().apply {
            put("network", transport)
            when (security) {
                "tls" -> { put("security", "tls"); put("tlsSettings", JSONObject().apply {
                    put("serverName", sni); put("allowInsecure", false)
                    q["fp"]?.let { put("fingerprint", it) }
                    q["alpn"]?.let { put("alpn", JSONArray(it.split(","))) }
                }) }
                "reality" -> { put("security", "reality"); put("realitySettings", JSONObject().apply {
                    put("serverName", sni); put("fingerprint", q["fp"] ?: "chrome")
                    put("shortId", q["sid"] ?: ""); put("publicKey", q["pbk"] ?: "")
                }) }
                else -> put("security", "none")
            }
            when (transport) {
                "ws" -> put("wsSettings", JSONObject().apply {
                    put("path", q["path"] ?: "/"); put("headers", JSONObject().apply { put("Host", q["host"] ?: sni) })
                })
                "grpc" -> put("grpcSettings", JSONObject().apply { put("serviceName", q["serviceName"] ?: "") })
                "h2", "http" -> put("httpSettings", JSONObject().apply {
                    put("host", JSONArray().apply { put(sni) }); put("path", q["path"] ?: "/")
                })
                "xhttp" -> put("xhttpSettings", JSONObject().apply {
                    put("path", q["path"] ?: "/")
                    q["host"]?.takeIf { it.isNotBlank() }?.let { put("host", it) }
                    q["mode"]?.takeIf { it.isNotBlank() }?.let { put("mode", it) }
                })
            }
        }
    }

    private fun parseQuery(q: String): Map<String, String> {
        if (q.isEmpty()) return emptyMap()
        return q.split("&").mapNotNull { p ->
            val i = p.indexOf('=')
            if (i >= 0) p.substring(0, i) to java.net.URLDecoder.decode(p.substring(i + 1), "UTF-8") else null
        }.toMap()
    }

    private fun splitHostPort(hp: String): Pair<String, Int> {
        if (hp.startsWith("[")) { val e = hp.indexOf(']'); return hp.substring(1, e) to (hp.substring(e + 2).toIntOrNull() ?: 443) }
        val i = hp.lastIndexOf(':')
        return if (i < 0) hp to 443 else hp.substring(0, i) to (hp.substring(i + 1).toIntOrNull() ?: 443)
    }

    private fun padBase64(s: String): String { val r = s.length % 4; return if (r == 0) s else s + "=".repeat(4 - r) }

    // ─── Flutter notifications ────────────────────────────────────────────────

    private fun notifyConnected() = postToFlutter("onConnected")
    private fun notifyDisconnected() = postToFlutter("onDisconnected")
    private fun notifyError(msg: String) { postToFlutter("onError", msg); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }

    // ─── Android notification ─────────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "ChrNet VPN", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Статус VPN подключения" }
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
    }

    private fun buildNotification(text: String): Notification {
        val stop = PendingIntent.getService(this, 0,
            Intent(this, XrayVpnService::class.java).apply { action = ACTION_STOP }, PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("ChrNet VPN")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .addAction(android.R.drawable.ic_media_pause, "Отключить", stop)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun buildSpeedNotificationText(downloadSpeed: Long, uploadSpeed: Long): String {
        return "\u2193 ${formatSpeed(downloadSpeed)}   \u2191 ${formatSpeed(uploadSpeed)}"
    }

    private fun smoothSpeedSample(speed: Long, samples: ArrayDeque<Long>): Long {
        samples.addLast(speed)
        while (samples.size > 4) {
            samples.removeFirst()
        }

        val average = samples.sum() / samples.size.coerceAtLeast(1)
        if (speed == 0L && average < 64L) {
            return 0L
        }
        return average
    }

    private fun formatSpeed(bytesPerSecond: Long): String {
        if (bytesPerSecond <= 0L) return "0 Б/с"
        if (bytesPerSecond < 1024L) return "$bytesPerSecond Б/с"
        if (bytesPerSecond < 1024L * 1024L) {
            return String.format("%.1f КБ/с", bytesPerSecond / 1024.0)
        }
        return String.format("%.1f МБ/с", bytesPerSecond / (1024.0 * 1024.0))
    }
}
