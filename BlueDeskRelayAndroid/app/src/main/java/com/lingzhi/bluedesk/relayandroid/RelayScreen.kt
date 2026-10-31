package com.lingzhi.bluedesk.relayandroid

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

private val Bg = Color(0xFF080909)
private val SurfaceColor = Color(0xFF171412)
private val Orange = Color(0xFFF56A1F)
private val Ink = Color(0xFFF2EDE7)
private val Muted = Color(0xFF9E958C)
private val DividerColor = Color(0xFF2C2621)
private val Good = Color(0xFF6FBF73)
private val Warn = Color(0xFFE0A458)
private val Bad = Color(0xFFE05C5C)

@Composable
fun RelayTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Orange,
            onPrimary = Color(0xFF1A0C04),
            secondary = Orange,
            onSecondary = Color(0xFF1A0C04),
            background = Bg,
            onBackground = Ink,
            surface = SurfaceColor,
            onSurface = Ink,
            surfaceVariant = Color(0xFF221D19),
            onSurfaceVariant = Muted,
            outline = Color(0xFF3A322C)
        ),
        content = content
    )
}

@Composable
fun RelayRoot(
    state: ConnState,
    devices: List<PairedDevice>,
    records: List<RelayRecord>,
    background: Boolean,
    transferLimit: Long,
    snackbarHostState: SnackbarHostState,
    onReconnect: () -> Unit,
    onDisconnect: () -> Unit,
    onSelectDevice: (PairedDevice) -> Unit,
    onToggleBackground: (Boolean) -> Unit,
    onSendText: (String) -> Unit,
    onSendFiles: () -> Unit,
    onSendFolder: () -> Unit
) {
    Scaffold(
        containerColor = Bg,
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item { Header() }
            item {
                ConnectionCard(
                    state = state,
                    devices = devices,
                    background = background,
                    transferLimit = transferLimit,
                    onReconnect = onReconnect,
                    onDisconnect = onDisconnect,
                    onSelectDevice = onSelectDevice,
                    onToggleBackground = onToggleBackground
                )
            }
            item {
                SendCard(
                    onSendText = onSendText,
                    onSendFiles = onSendFiles,
                    onSendFolder = onSendFolder
                )
            }
            item {
                Text(
                    text = "收发记录",
                    color = Muted,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.padding(top = 6.dp)
                )
            }
            if (records.isEmpty()) {
                item {
                    Text(
                        text = "还没有记录。连接手机后，收到的文字与文件会显示在这里。",
                        color = Muted,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(vertical = 8.dp)
                    )
                }
            }
            items(records, key = { it.id }) { record -> RecordRow(record) }
        }
    }
}

@Composable
private fun Header() {
    Column(modifier = Modifier.padding(top = 8.dp)) {
        Text(
            text = "BlueDesk Relay",
            color = Ink,
            fontSize = 26.sp,
            fontWeight = FontWeight.SemiBold
        )
        Text(
            text = "手机中转站 · 蓝牙直连",
            color = Muted,
            fontSize = 12.sp,
            modifier = Modifier.padding(top = 2.dp)
        )
    }
}

@Composable
private fun ConnectionCard(
    state: ConnState,
    devices: List<PairedDevice>,
    background: Boolean,
    transferLimit: Long,
    onReconnect: () -> Unit,
    onDisconnect: () -> Unit,
    onSelectDevice: (PairedDevice) -> Unit,
    onToggleBackground: (Boolean) -> Unit
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = SurfaceColor),
        shape = RoundedCornerShape(18.dp)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .background(state.dotColor(), CircleShape)
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "连接状态",
                    color = Muted,
                    fontSize = 12.sp
                )
                Spacer(Modifier.weight(1f))
                Text(
                    text = state.statusLabel(),
                    color = state.dotColor(),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium
                )
            }

            Text(
                text = state.describe(),
                color = Ink,
                fontSize = 17.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.padding(top = 10.dp)
            )

            if (state is ConnState.Connected) {
                Text(
                    text = state.address,
                    color = Muted,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(top = 2.dp)
                )
            }

            Row(
                modifier = Modifier.padding(top = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                if (state is ConnState.Connected) {
                    Button(
                        onClick = onDisconnect,
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color(0xFF2A2320),
                            contentColor = Ink
                        )
                    ) { Text("断开") }
                } else {
                    Button(
                        onClick = onReconnect,
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Orange,
                            contentColor = Color(0xFF1A0C04)
                        )
                    ) { Text("连接") }
                }
                OutlinedButton(
                    onClick = onReconnect,
                    shape = RoundedCornerShape(12.dp)
                ) { Text("重新连接") }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(text = "后台常驻", color = Ink, fontSize = 14.sp)
                    Text(
                        text = "通知栏常驻，开机自动连接",
                        color = Muted,
                        fontSize = 11.sp
                    )
                }
                Switch(
                    checked = background,
                    onCheckedChange = onToggleBackground,
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Color(0xFF1A0C04),
                        checkedTrackColor = Orange
                    )
                )
            }

            Text(
                text = "传输上限：${formatTransferLimit(transferLimit)}（由手机设置）",
                color = Muted,
                fontSize = 11.sp,
                modifier = Modifier.padding(top = 8.dp)
            )

            HorizontalDivider(
                modifier = Modifier.padding(vertical = 14.dp),
                color = DividerColor
            )

            Text(
                text = "已配对的 BlueDesk 手机",
                color = Muted,
                fontSize = 12.sp
            )
            if (devices.isEmpty()) {
                Text(
                    text = "没有找到配对的手机。请先在系统蓝牙设置里与本机配对（设备名以 BlueDesk 开头）。",
                    color = Muted,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(top = 8.dp)
                )
            } else {
                Column(
                    modifier = Modifier.padding(top = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    devices.forEach { device ->
                        val current = state is ConnState.Connected && state.address == device.address
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = Color(0xFF211C18),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onSelectDevice(device) }
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = device.name,
                                    color = Ink,
                                    fontSize = 14.sp,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f)
                                )
                                Text(
                                    text = if (current) "已连接" else "连接",
                                    color = if (current) Good else Orange,
                                    fontSize = 12.sp
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SendCard(
    onSendText: (String) -> Unit,
    onSendFiles: () -> Unit,
    onSendFolder: () -> Unit
) {
    val clipboard = LocalClipboardManager.current
    var text by remember { mutableStateOf("") }

    Card(
        colors = CardDefaults.cardColors(containerColor = SurfaceColor),
        shape = RoundedCornerShape(18.dp)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(text = "发送到手机中转站", color = Ink, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 10.dp),
                placeholder = { Text("输入文字…", color = Muted) },
                minLines = 3,
                maxLines = 5,
                shape = RoundedCornerShape(12.dp)
            )
            Row(
                modifier = Modifier.padding(top = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Button(
                    onClick = {
                        if (text.isNotBlank()) {
                            onSendText(text.trim())
                            text = ""
                        }
                    },
                    enabled = text.isNotBlank(),
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Orange,
                        contentColor = Color(0xFF1A0C04)
                    )
                ) { Text("发送") }
                OutlinedButton(
                    onClick = onSendFiles,
                    shape = RoundedCornerShape(12.dp)
                ) { Text("发送文件") }
                OutlinedButton(
                    onClick = onSendFolder,
                    shape = RoundedCornerShape(12.dp)
                ) { Text("发送文件夹") }
            }
            TextButton(
                onClick = {
                    val pasted = clipboard.getText()?.text
                    if (!pasted.isNullOrBlank()) onSendText(pasted.trim())
                }
            ) { Text("粘贴剪贴板并发送", color = Orange, fontSize = 13.sp) }
        }
    }
}

@Composable
private fun RecordRow(record: RelayRecord) {
    Card(
        colors = CardDefaults.cardColors(containerColor = Color(0xFF141110)),
        shape = RoundedCornerShape(14.dp)
    ) {
        Row(modifier = Modifier.padding(12.dp)) {
            Box(
                modifier = Modifier
                    .width(3.dp)
                    .height(40.dp)
                    .background(if (record.inbound) Orange else Color(0xFF4E7D55), RoundedCornerShape(2.dp))
            )
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = if (record.inbound) "收到" else "发送",
                        color = if (record.inbound) Orange else Good,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = if (record.isFile) "文件" else "文字",
                        color = Muted,
                        fontSize = 11.sp
                    )
                }
                Text(
                    text = record.title,
                    color = Ink,
                    fontSize = 14.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 3.dp)
                )
                Row(
                    modifier = Modifier.padding(top = 4.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(text = formatTime(record.at), color = Muted, fontSize = 11.sp)
                    if (record.isFile) {
                        Spacer(Modifier.width(8.dp))
                        Text(text = formatSize(record.size), color = Muted, fontSize = 11.sp)
                    }
                    Spacer(Modifier.weight(1f))
                    Text(
                        text = record.status.label(),
                        color = record.status.color(),
                        fontSize = 11.sp
                    )
                }
            }
        }
    }
}

private fun ConnState.dotColor(): Color = when (this) {
    is ConnState.Connected -> Good
    is ConnState.Connecting -> Warn
    is ConnState.Error -> Bad
    ConnState.BluetoothOff -> Bad
    else -> Muted
}

private fun ConnState.statusLabel(): String = when (this) {
    ConnState.Idle -> "待连接"
    ConnState.BluetoothOff -> "蓝牙关闭"
    ConnState.NoDevice -> "无配对设备"
    is ConnState.Connecting -> "连接中"
    is ConnState.Connected -> "已连接"
    is ConnState.Error -> "连接异常"
}

private fun RecordStatus.label(): String = when (this) {
    RecordStatus.QUEUED -> "排队中"
    RecordStatus.SENDING -> "发送中"
    RecordStatus.SENT -> "已发送"
    RecordStatus.RECEIVED -> "已接收"
    RecordStatus.FAILED -> "失败"
}

private fun RecordStatus.color(): Color = when (this) {
    RecordStatus.QUEUED -> Muted
    RecordStatus.SENDING -> Warn
    RecordStatus.SENT -> Good
    RecordStatus.RECEIVED -> Orange
    RecordStatus.FAILED -> Bad
}

private fun formatTime(at: Long): String {
    val now = Calendar.getInstance()
    val then = Calendar.getInstance().apply { timeInMillis = at }
    val sameDay = now.get(Calendar.YEAR) == then.get(Calendar.YEAR) &&
        now.get(Calendar.DAY_OF_YEAR) == then.get(Calendar.DAY_OF_YEAR)
    val pattern = if (sameDay) "HH:mm" else "MM-dd HH:mm"
    return SimpleDateFormat(pattern, Locale.CHINA).format(Date(at))
}

private fun formatTransferLimit(limit: Long): String {
    if (limit <= 0L) return "不限"
    val mb = 1024L * 1024L
    return when {
        limit >= mb && limit % mb == 0L -> "${limit / mb} MB"
        limit >= mb -> String.format(Locale.US, "%.1f MB", limit / mb.toDouble())
        limit % 1024L == 0L -> "${limit / 1024L} KB"
        else -> "$limit B"
    }
}

private fun formatSize(size: Long): String = when {
    size <= 0L -> ""
    size < 1024L -> "$size B"
    size < 1024L * 1024L -> String.format(Locale.US, "%.1f KB", size / 1024.0)
    else -> String.format(Locale.US, "%.1f MB", size / (1024.0 * 1024.0))
}
