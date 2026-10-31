package com.lingzhi.bluedesk.relayandroid

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * 常驻前台服务：保持与手机中转站的蓝牙连接，状态同步到常驻通知。
 * 行为对齐 Windows / macOS 辅助程序（后台运行、通知可见、进程被杀后可由系统重建）。
 */
class RelayService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var watchJob: Job? = null
    private var foregroundStarted = false

    override fun onCreate() {
        super.onCreate()
        RelayEngine.init(this)
        startForegroundCompat(RelayEngine.state.value)
        foregroundStarted = true
        RelayEngine.start()

        watchJob = scope.launch {
            RelayEngine.state.collect { state ->
                if (foregroundStarted) {
                    runCatching {
                        NotificationManagerCompat.from(this@RelayService)
                            .notify(Notifier.CONNECTION_ID, Notifier.connection(this@RelayService, state))
                    }
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        watchJob?.cancel()
        foregroundStarted = false
        RelayEngine.stop()
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundCompat(state: ConnState) {
        val notification = Notifier.connection(this, state)
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        } else {
            0
        }
        ServiceCompat.startForeground(this, Notifier.CONNECTION_ID, notification, type)
    }

    companion object {
        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, RelayService::class.java)
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RelayService::class.java))
        }
    }
}
