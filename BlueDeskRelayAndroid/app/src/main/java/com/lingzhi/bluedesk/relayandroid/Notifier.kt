package com.lingzhi.bluedesk.relayandroid

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** 通知渠道与三类通知：常驻连接、收到文字、收到文件 */
object Notifier {

    const val CONNECTION_ID = 1001
    private const val CH_CONNECTION = "connection"
    private const val CH_RECEIVED = "received"

    fun init(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                CH_CONNECTION,
                context.getString(R.string.channel_connection),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = context.getString(R.string.channel_connection_desc)
                setShowBadge(false)
            }
        )
        manager.createNotificationChannel(
            NotificationChannel(
                CH_RECEIVED,
                context.getString(R.string.channel_received),
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = context.getString(R.string.channel_received_desc)
            }
        )
    }

    /** 前台服务的常驻通知 */
    fun connection(context: Context, state: ConnState): Notification {
        val connected = state is ConnState.Connected
        return NotificationCompat.Builder(context, CH_CONNECTION)
            .setSmallIcon(R.drawable.ic_stat_relay)
            .setContentTitle("BlueDesk Relay")
            .setContentText(state.describe(context))
            .setContentIntent(openApp(context))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setCategory(if (connected) NotificationCompat.CATEGORY_SERVICE else NotificationCompat.CATEGORY_STATUS)
            .build()
    }

    fun receivedText(context: Context, text: String) {
        val notification = NotificationCompat.Builder(context, CH_RECEIVED)
            .setSmallIcon(R.drawable.ic_stat_relay)
            .setContentTitle(context.getString(R.string.notif_received_text))
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(openApp(context))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(2001, notification) }
    }

    fun receivedFile(context: Context, name: String, uri: Uri?, mime: String?) {
        val viewIntent = if (uri != null) {
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime ?: "*/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        } else {
            Intent(context, MainActivity::class.java)
        }
        val pending = PendingIntent.getActivity(
            context,
            if (uri != null) 3000 + uri.hashCode() else 3000,
            viewIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, CH_RECEIVED)
            .setSmallIcon(R.drawable.ic_stat_relay)
            .setContentTitle(context.getString(R.string.notif_received_file))
            .setContentText(name)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(3000 + (uri?.hashCode() ?: 0), notification) }
    }

    /** 文件夹接收完成：点击可打开首个文件（没有可读文件时回到 App） */
    fun receivedFolder(context: Context, name: String, files: Int, firstUri: Uri?) {
        val viewIntent = if (firstUri != null) {
            val mime = runCatching { context.contentResolver.getType(firstUri) }.getOrNull() ?: "*/*"
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(firstUri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        } else {
            Intent(context, MainActivity::class.java)
        }
        val id = 4000 + (firstUri?.hashCode() ?: name.hashCode())
        val pending = PendingIntent.getActivity(
            context,
            id,
            viewIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val text = context.getString(R.string.folder_notif_text, name, files)
        val notification = NotificationCompat.Builder(context, CH_RECEIVED)
            .setSmallIcon(R.drawable.ic_stat_relay)
            .setContentTitle(context.getString(R.string.notif_received_folder))
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(id, notification) }
    }

    private fun openApp(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
}
