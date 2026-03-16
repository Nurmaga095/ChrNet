package com.chrnet.vpn

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var activity: Activity? = null
    private var appContext: Context? = null
    private var pendingConfig: Map<String, Any>? = null
    private var pendingAction: PendingAction = PendingAction.CONNECT
    private val mainHandler = Handler(Looper.getMainLooper())
    private var permissionPollStartedAt = 0L

    private enum class PendingAction { CONNECT, RECONNECT }

    private val permissionPollRunnable = object : Runnable {
        override fun run() {
            val cfg = pendingConfig ?: return
            val ctx = activity ?: appContext ?: return
            val needsPermission = VpnService.prepare(ctx) != null
            if (!needsPermission) {
                Log.d("VpnPlugin", "VPN permission granted (poll), starting service")
                pendingConfig = null
                if (pendingAction == PendingAction.RECONNECT) {
                    restartVpnService(cfg)
                } else {
                    startVpnService(cfg)
                }
                return
            }

            val elapsed = System.currentTimeMillis() - permissionPollStartedAt
            if (elapsed > 30_000) {
                Log.w("VpnPlugin", "VPN permission timeout")
                pendingConfig = null
                XrayVpnService.postToFlutter("onError", "Не выдано VPN разрешение")
                return
            }
            mainHandler.postDelayed(this, 750)
        }
    }

    companion object {
        const val VPN_REQUEST_CODE = 1001
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, "com.chrnet.vpn/service")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "com.chrnet.vpn/stats")
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                XrayVpnService.eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                XrayVpnService.eventSink = null
            }
        })

        XrayVpnService.methodChannel = methodChannel
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connect" -> {
                val config = call.arguments as? Map<String, Any>
                if (config == null) {
                    result.error("INVALID_ARG", "Config is null", null)
                    return
                }
                requestVpnPermissionAndStart(config, reconnect = false)
                result.success(null)
            }
            "reconnect" -> {
                val config = call.arguments as? Map<String, Any>
                if (config == null) {
                    result.error("INVALID_ARG", "Config is null", null)
                    return
                }
                requestVpnPermissionAndStart(config, reconnect = true)
                result.success(null)
            }
            "disconnect" -> {
                val ctx = appContext ?: activity ?: run {
                    result.error("NO_CTX", "No context", null)
                    return
                }
                val intent = Intent(ctx, XrayVpnService::class.java).apply {
                    action = XrayVpnService.ACTION_STOP
                }
                ctx.startService(intent)
                result.success(null)
            }
            "syncQuickSettingsConfig" -> {
                val config = call.arguments as? Map<String, Any>
                val ctx = appContext ?: activity ?: run {
                    result.error("NO_CTX", "No context", null)
                    return
                }
                if (config == null) {
                    result.error("INVALID_ARG", "Config is null", null)
                    return
                }
                QuickSettingsStore.saveConfig(ctx, config)
                result.success(null)
            }
            "clearQuickSettingsConfig" -> {
                val ctx = appContext ?: activity ?: run {
                    result.error("NO_CTX", "No context", null)
                    return
                }
                QuickSettingsStore.clearConfig(ctx)
                result.success(null)
            }
            "getStatus" -> {
                result.success(XrayVpnService.isVpnRunning)
            }
            "getDeviceInfo" -> {
                val ctx = appContext ?: activity ?: run {
                    result.error("NO_CTX", "No context", null)
                    return
                }
                val deviceId = android.provider.Settings.Secure.getString(
                    ctx.contentResolver,
                    android.provider.Settings.Secure.ANDROID_ID
                ) ?: ""
                result.success(mapOf(
                    "deviceId" to deviceId,
                    "osVersion" to android.os.Build.VERSION.RELEASE,
                    "model" to android.os.Build.MODEL,
                ))
            }
            else -> result.notImplemented()
        }
    }

    private fun requestVpnPermissionAndStart(
        config: Map<String, Any>,
        reconnect: Boolean
    ) {
        val ctx = appContext ?: activity
        if (ctx != null) {
            QuickSettingsStore.saveConfig(ctx, config)
        }
        val act = activity
        val action = if (reconnect) PendingAction.RECONNECT else PendingAction.CONNECT
        if (act == null) {
            // Нет активити — пробуем сразу запустить (разрешение могло быть выдано ранее)
            Log.d("VpnPlugin", "No activity, starting VPN service directly")
            if (action == PendingAction.RECONNECT) {
                restartVpnService(config)
            } else {
                startVpnService(config)
            }
            return
        }
        val intent = VpnService.prepare(act)
        if (intent != null) {
            Log.d("VpnPlugin", "Requesting VPN permission via activity result")
            pendingConfig = config
            pendingAction = action
            permissionPollStartedAt = System.currentTimeMillis()
            mainHandler.removeCallbacks(permissionPollRunnable)
            mainHandler.postDelayed(permissionPollRunnable, 750)
            act.startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            Log.d("VpnPlugin", "VPN permission already granted, starting service")
            if (action == PendingAction.RECONNECT) {
                restartVpnService(config)
            } else {
                startVpnService(config)
            }
        }
    }

    private fun startVpnService(config: Map<String, Any>) {
        // Используем applicationContext — не зависит от жизненного цикла Activity
        val ctx = appContext ?: activity ?: return
        mainHandler.removeCallbacks(permissionPollRunnable)
        val intent = Intent(ctx, XrayVpnService::class.java).apply {
            putExtra("config", config["rawUri"] as? String ?: "")
            putExtra("ruRouting", config["ruRouting"] as? Boolean ?: true)
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            ctx.startForegroundService(intent)
        } else {
            ctx.startService(intent)
        }
    }

    private fun restartVpnService(config: Map<String, Any>) {
        val ctx = appContext ?: activity ?: return
        mainHandler.removeCallbacks(permissionPollRunnable)
        val intent = Intent(ctx, XrayVpnService::class.java).apply {
            action = XrayVpnService.ACTION_RESTART
            putExtra("config", config["rawUri"] as? String ?: "")
            putExtra("ruRouting", config["ruRouting"] as? Boolean ?: true)
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            ctx.startForegroundService(intent)
        } else {
            ctx.startService(intent)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == VPN_REQUEST_CODE) {
            mainHandler.removeCallbacks(permissionPollRunnable)
            if (resultCode == Activity.RESULT_OK) {
                Log.d("VpnPlugin", "VPN permission granted (activity result)")
                pendingConfig?.let {
                    if (pendingAction == PendingAction.RECONNECT) {
                        restartVpnService(it)
                    } else {
                        startVpnService(it)
                    }
                }
            } else {
                Log.w("VpnPlugin", "VPN permission denied by user")
                XrayVpnService.postToFlutter("onError", "Пользователь отклонил VPN разрешение")
            }
            pendingConfig = null
            pendingAction = PendingAction.CONNECT
            return true
        }
        return false
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivity() { activity = null }
}
