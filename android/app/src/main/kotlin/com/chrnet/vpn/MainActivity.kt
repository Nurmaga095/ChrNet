package com.chrnet.vpn

import android.content.Intent
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var vpnPlugin: VpnPlugin? = null
    private val deepLinkChannel = "com.chrnet.vpn/deep_link"

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        vpnPlugin = VpnPlugin()
        flutterEngine.plugins.add(vpnPlugin!!)
    }

    override fun onStart() {
        super.onStart()
        // Handle deep link that launched the app fresh
        intent?.data?.toString()?.let { sendDeepLink(it) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Handle deep link when app is already running (singleTop)
        intent.data?.toString()?.let { sendDeepLink(it) }
    }

    private fun sendDeepLink(url: String) {
        if (!url.startsWith("chrnet://add/", ignoreCase = true)) return
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
            MethodChannel(messenger, deepLinkChannel)
                .invokeMethod("onDeepLink", url)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // Гарантируем доставку результата VPN-диалога в плагин
        if (vpnPlugin?.onActivityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
