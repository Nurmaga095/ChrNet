package com.chrnet.vpn

import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast

class VpnTileService : TileService() {

    override fun onTileAdded() {
        super.onTileAdded()
        updateTile()
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        unlockAndRun {
            if (XrayVpnService.isVpnRunning) {
                stopVpn()
            } else {
                startVpnFromTile()
            }
            updateTile()
        }
    }

    private fun startVpnFromTile() {
        val config = QuickSettingsStore.loadConfig(this)
        if (config == null) {
            Toast.makeText(this, "Сначала выберите сервер в приложении", Toast.LENGTH_SHORT).show()
            openApp()
            return
        }

        if (VpnService.prepare(this) != null) {
            Toast.makeText(
                this,
                "Откройте приложение и выдайте VPN-разрешение один раз",
                Toast.LENGTH_SHORT,
            ).show()
            openApp()
            return
        }

        val intent = QuickSettingsStore.buildStartIntent(this, config)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopVpn() {
        startService(
            Intent(this, XrayVpnService::class.java).apply {
                action = XrayVpnService.ACTION_STOP
            },
        )
    }

    private fun openApp() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            ?: Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pendingIntent = PendingIntent.getActivity(
                this,
                1002,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(launchIntent)
        }
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val hasConfig = QuickSettingsStore.loadConfig(this) != null

        tile.label = "ChrNet VPN"
        tile.state = when {
            XrayVpnService.isVpnRunning -> Tile.STATE_ACTIVE
            hasConfig -> Tile.STATE_INACTIVE
            else -> Tile.STATE_UNAVAILABLE
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when {
                XrayVpnService.isVpnRunning -> "Включен"
                hasConfig -> "Выключен"
                else -> "Нет сервера"
            }
        }

        tile.contentDescription = tile.label
        tile.updateTile()
    }
}
