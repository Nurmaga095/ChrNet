package com.chrnet.vpn

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService

data class StoredVpnConfig(
    val rawUri: String,
    val ruRouting: Boolean,
)

object QuickSettingsStore {
    private const val PREFS_NAME = "chrnet_quick_settings"
    private const val KEY_RAW_URI = "raw_uri"
    private const val KEY_RU_ROUTING = "ru_routing"

    fun saveConfig(context: Context, config: Map<String, Any>) {
        val rawUri = config["rawUri"] as? String
        if (rawUri.isNullOrBlank()) return

        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_RAW_URI, rawUri)
            .putBoolean(KEY_RU_ROUTING, config["ruRouting"] as? Boolean ?: false)
            .apply()

        requestTileRefresh(context)
    }

    fun clearConfig(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .apply()

        requestTileRefresh(context)
    }

    fun loadConfig(context: Context): StoredVpnConfig? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val rawUri = prefs.getString(KEY_RAW_URI, null)
        if (rawUri.isNullOrBlank()) return null

        return StoredVpnConfig(
            rawUri = rawUri,
            ruRouting = prefs.getBoolean(KEY_RU_ROUTING, false),
        )
    }

    fun buildStartIntent(context: Context, config: StoredVpnConfig): Intent {
        return Intent(context, XrayVpnService::class.java).apply {
            putExtra("config", config.rawUri)
            putExtra("ruRouting", config.ruRouting)
        }
    }

    fun requestTileRefresh(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return

        TileService.requestListeningState(
            context,
            ComponentName(context, VpnTileService::class.java),
        )
    }
}
