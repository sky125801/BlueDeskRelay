package com.lingzhi.bluedesk.relayandroid

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/** 开机自启：已开启「后台常驻」且拿到蓝牙权限时，直接拉起前台服务 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs = context.getSharedPreferences("relay_prefs", Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_BACKGROUND, true)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val granted = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) return
        }
        runCatching { RelayService.start(context) }
    }

    companion object {
        const val KEY_BACKGROUND = "background_service"
    }
}
