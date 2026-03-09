package com.chrnet.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences

/**
 * BootReceiver — запускает VPN при включении устройства
 * если настройка "Автозапуск" включена.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val prefs: SharedPreferences =
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

        val autoStart = prefs.getBoolean("flutter.autoStart", false)
        val selectedServerId = prefs.getString("flutter.selectedServerId", null)

        if (autoStart && selectedServerId != null) {
            val serviceIntent = Intent(context, XrayVpnService::class.java).apply {
                putExtra("autoStart", true)
            }
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        }
    }
}
