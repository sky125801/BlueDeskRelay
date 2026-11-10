package com.lingzhi.bluedesk.relayandroid

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.UUID
import kotlin.random.Random

/** 连接状态（UI、通知、引擎共用） */
sealed interface ConnState {
    data object Idle : ConnState
    data object BluetoothOff : ConnState
    data object NoDevice : ConnState
    data class Connecting(val name: String) : ConnState
    data class Connected(val name: String, val address: String) : ConnState
    data class Error(val message: String) : ConnState
}

fun ConnState.describe(context: Context): String = when (this) {
    ConnState.Idle -> context.getString(R.string.state_idle)
    ConnState.BluetoothOff -> context.getString(R.string.state_bluetooth_off)
    ConnState.NoDevice -> context.getString(R.string.state_no_device)
    is ConnState.Connecting -> context.getString(R.string.state_connecting, name)
    is ConnState.Connected -> context.getString(R.string.state_connected, name)
    is ConnState.Error -> message
}

enum class RecordStatus { QUEUED, SENDING, SENT, RECEIVED, FAILED }

data class RelayRecord(
    val id: String,
    val inbound: Boolean,
    val isFile: Boolean,
    val title: String,
    val text: String? = null,
    val uri: Uri? = null,
    val mime: String? = null,
    val size: Long = 0,
    val at: Long = System.currentTimeMillis(),
    val status: RecordStatus = RecordStatus.QUEUED,
)

data class PairedDevice(val name: String, val address: String)

/**
 * 中转客户端核心：连上手机端的 BlueDesk 服务，收发文字与文件。
 *
 * 行为对齐 Windows / macOS 辅助程序：
 *  - 连接后先发 HELLO（本机名），手机端据此显示设备名；
 *  - 蓝牙控制链路常驻；手机下发 NET_INFO 后再开一条独立 TCP 数据链路（role=data），
 *    文件/文件夹走数据链路，文本与控制帧仍走蓝牙；
 *  - 收 TEXT → 写剪贴板并通知；收 FILE_META/CHUNK/END → 存 Download/BlueDesk；
 *  - 收到的 needAck 帧回 ACK，PING 回 PONG；
 *  - 断线每 5 秒自动重连；发送内容在未连接时排队。
 */
object RelayEngine {

    private const val TAG = "RelayEngine"
    private const val PREFS = "relay_prefs"
    private const val KEY_MAC = "peer_mac"
    private const val KEY_NAME = "peer_name"
    /** 手机 Wi-Fi 数据通道端点（来自 NET_INFO） */
    private const val KEY_WIFI_HOST = "wifi_host"
    private const val KEY_WIFI_PORT = "wifi_port"
    /** 本机稳定标识：走 TCP 时手机拿不到 MAC，靠它把会话认回同一台设备 */
    private const val KEY_PEER_ID = "peer_id"
    private const val RETRY_MS = 5_000L
    private const val CONNECT_TIMEOUT_MS = 15_000L
    /** 独立 TCP 数据链路：探测 4 秒，失败后 5~10 秒重试 */
    private const val DATA_CONNECT_TIMEOUT_MS = 4_000
    private const val DATA_RETRY_MIN_MS = 5_000L
    private const val DATA_RETRY_JITTER_MS = 5_000L
    /** 没有蓝牙可用时，用记住的端点把整条会话跑在 TCP 上（老兜底模式） */
    private const val WIFI_CONNECT_TIMEOUT_MS = 4_000
    private const val WIFI_FAILURE_LIMIT = 3
    private const val WIFI_COOLDOWN_MS = 60_000L
    private const val DEFAULT_WIFI_PORT = 47654
    private const val WIFI_CHUNK = 64 * 1024

    private lateinit var app: Context
    private lateinit var prefs: SharedPreferences

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val fileMutex = Mutex()

    private val _state = MutableStateFlow<ConnState>(ConnState.Idle)
    val state: StateFlow<ConnState> = _state.asStateFlow()

    private val _records = MutableStateFlow<List<RelayRecord>>(emptyList())
    val records: StateFlow<List<RelayRecord>> = _records.asStateFlow()

    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 16)
    val messages: SharedFlow<String> = _messages.asSharedFlow()

    /** 手机端下发的传输上限（字节），0 表示不限；默认 64MB */
    private val _transferLimit = MutableStateFlow(RelayProtocol.MAX_FILE)
    val transferLimit: StateFlow<Long> = _transferLimit.asStateFlow()

    private val outgoing = Channel<Outgoing>(Channel.UNLIMITED)
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val dataWake = Channel<Unit>(Channel.CONFLATED)

    /** 蓝牙控制链路（没有蓝牙可用时，也可能是整条走 TCP 的兜底链路） */
    @Volatile
    private var controlLink: Link? = null

    /** 独立的 TCP 数据链路：只跑批量文件帧，与蓝牙控制链路并存 */
    @Volatile
    private var dataLink: Link? = null

    /** 等待数据链路超时后的冷却截止时间，避免每个文件都白等 */
    @Volatile
    private var dataLinkWaitSkippedUntil = 0L

    @Volatile
    private var pendingSocket: BluetoothSocket? = null

    /** 数据链路分块大小：手机通过 NET_INFO 的 chunk 下发，默认 64 KB */
    @Volatile
    private var dataChunk = WIFI_CHUNK

    private var wifiFailures = 0
    private var wifiCooldownUntil = 0L

    private var supervisorJob: Job? = null
    private var workerJob: Job? = null
    private var dataJob: Job? = null

    @Volatile
    private var running = false

    @Volatile
    private var paused = false

    private sealed interface Outgoing {
        data class TextTask(val recordId: String, val text: String) : Outgoing
        data class FileTask(val file: File, val name: String, val recordId: String) : Outgoing
        data class TreeTask(
            val recordId: String,
            val name: String,
            val files: List<TreeEntry>,
            val dirs: List<String>,
            val totalBytes: Long,
        ) : Outgoing
    }

    private data class FileMetaInfo(val name: String, val size: Long)

    private data class TreeEntry(val uri: Uri, val path: String, val size: Long)

    /** 一次文件夹接收的上下文（随连接存活，BATCH_END 或连接断开时重置） */
    private class BatchReceiver {
        var active = false
        var id = ""
        var name = ""
        var basePath = ""
        var dirs: List<String> = emptyList()
        var expectedFiles = 0
        var declaredBytes = 0L
        var receivedBytes = 0L
        var receivedFiles = 0
        var rejected = false
        var strayFile = false
        var currentPath = ""
        var firstUri: Uri? = null

        fun start(id: String, folder: String, files: Int, bytes: Long, dirs: List<String>) {
            active = true
            this.id = id
            name = folder
            basePath = "Download/BlueDesk/$folder"
            this.dirs = dirs
            expectedFiles = files
            declaredBytes = bytes
            receivedBytes = 0
            receivedFiles = 0
            rejected = false
            strayFile = false
            currentPath = ""
            firstUri = null
        }

        fun reset() {
            active = false
            id = ""
            name = ""
            basePath = ""
            dirs = emptyList()
            expectedFiles = 0
            declaredBytes = 0
            receivedBytes = 0
            receivedFiles = 0
            rejected = false
            strayFile = false
            currentPath = ""
            firstUri = null
        }

        val discarding: Boolean get() = rejected || strayFile
    }

    /**
     * 一条已建立的通道。
     *
     * 蓝牙控制链路常驻；数据链路是手机同意的额外 TCP，只跑批量文件帧。
     * 每条通道各自持有分块大小与写锁，两条链路上的帧不会互相交错。
     */
    private class Link(
        val label: String,
        val socket: Closeable,
        val input: DataInputStream,
        val output: DataOutputStream,
        /** 蓝牙链路受 MTU 限制，只有它可以承载控制帧 */
        val isBluetooth: Boolean,
        @Volatile var chunk: Int,
    ) {
        private val writeMutex = Mutex()

        suspend fun send(frame: RelayProtocol.Frame) = writeMutex.withLock {
            RelayProtocol.write(output, frame)
        }

        fun close() {
            runCatching { socket.close() }
        }
    }

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        Notifier.init(app)
        ensureWorker()
        ensureDataWorker()
    }

    // ------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------

    fun start() {
        if (!::app.isInitialized) return
        if (running) {
            wake.trySend(Unit)
            return
        }
        running = true
        paused = false
        ensureSupervisor()
        ensureDataWorker()
    }

    fun stop() {
        running = false
        supervisorJob?.cancel()
        supervisorJob = null
        dataJob?.cancel()
        dataJob = null
        closeLinks()
        _state.value = ConnState.Idle
    }

    fun disconnect() {
        paused = true
        closeLinks()
        _state.value = ConnState.Idle
    }

    fun reconnect() {
        paused = false
        wake.trySend(Unit)
        dataWake.trySend(Unit)
        if (!running) start()
    }

    fun connectTo(device: PairedDevice) {
        prefs.edit().putString(KEY_MAC, device.address).putString(KEY_NAME, device.name).apply()
        reconnect()
    }

    /** 已配对且名字像 BlueDesk 的手机；没有蓝牙权限时返回空列表 */
    fun pairedDevices(): List<PairedDevice> {
        if (!::app.isInitialized || !hasConnectPermission()) return emptyList()
        val adapter = bluetoothAdapter() ?: return emptyList()
        return runCatching {
            adapter.bondedDevices.orEmpty()
                .mapNotNull { device ->
                    val name = deviceNameSafe(device) ?: return@mapNotNull null
                    if (!name.startsWith("BlueDesk", ignoreCase = true)) return@mapNotNull null
                    PairedDevice(name, device.address)
                }
                .sortedBy { it.name }
        }.getOrDefault(emptyList())
    }

    fun sendText(text: String) {
        if (!::app.isInitialized || text.isBlank()) return
        val id = newId()
        addRecord(
            RelayRecord(
                id = id, inbound = false, isFile = false, title = text,
                text = text, size = text.toByteArray(Charsets.UTF_8).size.toLong(),
                status = RecordStatus.QUEUED
            )
        )
        outgoing.trySend(Outgoing.TextTask(id, text))
    }

    /** 从系统分享 / 文件选择器拿到的文件，先复制到缓存，断开时也能排队 */
    fun sendUris(uris: List<Uri>) {
        if (!::app.isInitialized || uris.isEmpty()) return
        scope.launch {
            for (uri in uris) {
                try {
                    val meta = queryMeta(uri)
                    if (!withinLimit(meta.size)) {
                        emitMessage(app.getString(R.string.msg_exceeds_limit, meta.name, limitLabel()))
                        continue
                    }
                    val cached = copyToCache(uri, meta.name)
                    if (cached == null) {
                        emitMessage(app.getString(R.string.msg_cannot_read_file, meta.name))
                        continue;
                    }
                    if (!withinLimit(cached.length())) {
                        cached.delete()
                        emitMessage(app.getString(R.string.msg_exceeds_limit, meta.name, limitLabel()))
                        continue;
                    }
                    val id = newId()
                    addRecord(
                        RelayRecord(
                            id = id, inbound = false, isFile = true, title = meta.name,
                            size = cached.length(), status = RecordStatus.QUEUED
                        )
                    )
                    outgoing.send(Outgoing.FileTask(cached, meta.name, id))
                } catch (e: Exception) {
                    Log.w(TAG, "读取待发送文件失败", e)
                    emitMessage(app.getString(R.string.msg_read_file_failed, e.message ?: app.getString(R.string.msg_unknown_error)))
                }
            }
        }
    }

    /**
     * 发送整个文件夹：递归遍历 DocumentFile，统计总量并按当前传输上限校验，
     * 然后 BATCH_META → 逐文件 (FILE_META + 4KB CHUNK* + FILE_END) → BATCH_END。
     * 读取权限的持久化由调用方（选择文件夹的 Activity）负责。
     */
    fun sendTree(treeUri: Uri) {
        if (!::app.isInitialized) return
        scope.launch {
            try {
                val root = DocumentFile.fromTreeUri(app, treeUri)
                if (root == null || !root.canRead()) {
                    emitMessage(app.getString(R.string.msg_cannot_read_folder))
                    return@launch
                }
                val files = mutableListOf<TreeEntry>()
                val dirs = mutableListOf<String>()
                collectTree(root, "", files, dirs)
                if (files.isEmpty() && dirs.isEmpty()) {
                    emitMessage(app.getString(R.string.msg_folder_empty))
                    return@launch
                }
                // SAF 可能返回 -1（大小未知），声明总量只统计已知大小；
                // 未知部分由发送时的累计字节数与手机端累计校验兜底。
                val total = files.sumOf { if (it.size >= 0L) it.size else 0L }
                if (!withinLimit(total)) {
                    emitMessage(app.getString(R.string.msg_folder_exceeds_limit, limitLabel()))
                    return@launch
                }
                val rawName = root.name?.takeIf { it.isNotBlank() } ?: app.getString(R.string.folder_default_name)
                val name = sanitizeName(rawName)
                val id = newId()
                addRecord(
                    RelayRecord(
                        id = id, inbound = false, isFile = true,
                        title = app.getString(R.string.folder_record_title, name, files.size),
                        size = total, status = RecordStatus.QUEUED
                    )
                )
                outgoing.send(Outgoing.TreeTask(id, name, files, dirs, total))
            } catch (e: Exception) {
                Log.w(TAG, "读取待发送文件夹失败", e)
                emitMessage(app.getString(R.string.msg_read_folder_failed, e.message ?: app.getString(R.string.msg_unknown_error)))
            }
        }
    }

    private fun collectTree(
        dir: DocumentFile,
        prefix: String,
        files: MutableList<TreeEntry>,
        dirs: MutableList<String>,
    ) {
        for (child in dir.listFiles()) {
            val childName = sanitizeName(child.name ?: continue)
            val rel = if (prefix.isEmpty()) childName else "$prefix/$childName"
            if (child.isDirectory) {
                dirs += rel
                collectTree(child, rel, files, dirs)
            } else if (child.isFile) {
                files += TreeEntry(child.uri, rel, child.length())
            }
        }
    }

    // ------------------------------------------------------------
    // 连接守护
    // ------------------------------------------------------------

    private fun ensureSupervisor() {
        if (supervisorJob?.isActive == true) return
        supervisorJob = scope.launch {
            while (running) {
                if (paused) {
                    withTimeoutOrNull(1000L) { wake.receive() }
                    continue
                }
                if (controlLink != null) {
                    withTimeoutOrNull(1000L) { wake.receive() }
                    continue
                }
                try {
                    connectOnce()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.w(TAG, "连接循环异常：${e.message}")
                }
                if (running && controlLink == null) {
                    withTimeoutOrNull(RETRY_MS) { wake.receive() }
                }
            }
        }
    }

    private suspend fun connectOnce() = withContext(Dispatchers.IO) {
        val adapter = bluetoothAdapter()
        if (adapter == null) {
            if (tryConnectWifiOnly()) return@withContext
            _state.value = ConnState.Error(app.getString(R.string.state_error_bluetooth_unsupported))
            return@withContext
        }
        if (!hasConnectPermission()) {
            if (tryConnectWifiOnly()) return@withContext
            _state.value = ConnState.Error(app.getString(R.string.state_error_no_permission))
            return@withContext
        }
        if (!runCatching { adapter.isEnabled }.getOrDefault(false)) {
            if (tryConnectWifiOnly()) return@withContext
            _state.value = ConnState.BluetoothOff
            return@withContext
        }

        val savedMac = prefs.getString(KEY_MAC, null)
        val device = savedMac?.let { mac -> runCatching { adapter.getRemoteDevice(mac) }.getOrNull() }
            ?: findBlueDeskDevice(adapter)
        if (device == null) {
            if (tryConnectWifiOnly()) return@withContext
            _state.value = ConnState.NoDevice
            return@withContext
        }

        val name = deviceNameSafe(device) ?: prefs.getString(KEY_NAME, null) ?: device.address
        _state.value = ConnState.Connecting(name)

        var connecting: BluetoothSocket? = null
        try {
            runCatching { adapter.cancelDiscovery() }
            val s = device.createRfcommSocketToServiceRecord(RelayProtocol.SERVICE_UUID)
            connecting = s
            pendingSocket = s

            val attempt = scope.async(Dispatchers.IO) {
                runCatching { s.connect() }.isSuccess
            }
            val connected = withTimeoutOrNull(CONNECT_TIMEOUT_MS) { attempt.await() } ?: false
            if (!connected) {
                runCatching { s.close() }
                attempt.cancel()
                throw IOException(app.getString(R.string.state_connect_failed))
            }

            pendingSocket = null
            val link = Link(
                label = "bt:${device.address}",
                socket = s,
                input = DataInputStream(s.inputStream),
                output = DataOutputStream(s.outputStream),
                isBluetooth = true,
                chunk = RelayProtocol.MAX_CHUNK,     // 蓝牙受 MTU 限制，回到 4 KB
            )
            controlLink = link
            link.send(RelayProtocol.hello(localDeviceName()))
            link.send(RelayProtocol.ident(identJson("bt")))

            prefs.edit().putString(KEY_MAC, device.address).putString(KEY_NAME, name).apply()
            _state.value = ConnState.Connected(name, device.address)
            Log.i(TAG, "已连接 $name (${device.address})，控制链路走蓝牙")
            dataWake.trySend(Unit)      // 蓝牙控制链路就绪后才去开数据链路

            readLoop(link)

            closeLinks()
            if (running) _state.value = ConnState.Idle
        } catch (e: CancellationException) {
            runCatching { connecting?.close() }
            throw e
        } catch (e: Exception) {
            runCatching { connecting?.close() }
            closeLinks()
            _state.value = ConnState.Error(friendlyError(e))
            Log.w(TAG, "连接失败：${e.message}")
        } finally {
            pendingSocket = null
        }
    }

    /**
     * 没有蓝牙可用时的兜底：直接用记住的 Wi-Fi 端点把整条会话跑在 TCP 上。
     *
     * 这种模式没有蓝牙控制会话可挂，IDENT 不带 role，手机按「整条会话切 TCP」处理。
     */
    private suspend fun tryConnectWifiOnly(): Boolean {
        if (System.currentTimeMillis() < wifiCooldownUntil) return false
        val endpoint = savedEndpoint() ?: return false
        val (host, port) = endpoint

        val name = prefs.getString(KEY_NAME, null) ?: "BlueDesk"
        _state.value = ConnState.Connecting(name)

        val s = java.net.Socket()
        try {
            val attempt = scope.async(Dispatchers.IO) {
                runCatching {
                    s.connect(java.net.InetSocketAddress(host, port), WIFI_CONNECT_TIMEOUT_MS)
                }.isSuccess
            }
            val ok = withTimeoutOrNull(WIFI_CONNECT_TIMEOUT_MS + 1_000L) { attempt.await() } ?: false
            if (!ok) {
                attempt.cancel()
                runCatching { s.close() }
                onWifiFailed(host, port)
                return false
            }

            configureTcp(s)
            val link = Link(
                label = "tcp:$host:$port",
                socket = s,
                input = DataInputStream(s.getInputStream()),
                output = DataOutputStream(s.getOutputStream()),
                isBluetooth = false,
                chunk = dataChunk,
            )
            controlLink = link
            link.send(RelayProtocol.hello(localDeviceName()))
            link.send(RelayProtocol.ident(identJson("tcp")))

            wifiFailures = 0
            wifiCooldownUntil = 0L
            _state.value = ConnState.Connected(name, "$host:$port")
            Log.i(TAG, "已连接 $name（整条会话走 Wi-Fi $host:$port）")

            readLoop(link)
            closeLinks()
            if (running) _state.value = ConnState.Idle
            return true
        } catch (e: CancellationException) {
            runCatching { s.close() }
            throw e
        } catch (e: Exception) {
            runCatching { s.close() }
            closeLinks()
            _state.value = ConnState.Error(friendlyError(e))
            Log.w(TAG, "Wi-Fi 连接失败：${e.message}")
            return false
        }
    }

    // ------------------------------------------------------------
    // 独立数据链路（蓝牙控制链路常驻，文件帧走这条 TCP）
    // ------------------------------------------------------------

    private fun ensureDataWorker() {
        if (dataJob?.isActive == true) return
        dataJob = scope.launch {
            while (running) {
                val control = controlLink
                if (paused || control == null || !control.isBluetooth || dataLink != null) {
                    withTimeoutOrNull(1000L) { dataWake.receive() }
                    continue
                }
                val endpoint = savedEndpoint()
                if (endpoint == null) {
                    withTimeoutOrNull(1000L) { dataWake.receive() }
                    continue
                }
                try {
                    connectDataLink(control, endpoint.first, endpoint.second)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.w(TAG, "数据链路异常：${e.message}")
                }
                // 只在蓝牙控制链路在线时重试，间隔 5~10 秒
                if (running && controlLink != null && dataLink == null) {
                    val retry = DATA_RETRY_MIN_MS + Random.nextLong(DATA_RETRY_JITTER_MS + 1)
                    Log.i(TAG, "数据链路未就绪，${retry / 1000} 秒后重试")
                    withTimeoutOrNull(retry) { dataWake.receive() }
                }
            }
        }
    }

    /** 连上数据链路并跑接收循环；只有蓝牙控制链路在线时才调用 */
    private suspend fun connectDataLink(control: Link, host: String, port: Int) {
        val s = java.net.Socket()
        try {
            val attempt = scope.async(Dispatchers.IO) {
                runCatching {
                    s.connect(java.net.InetSocketAddress(host, port), DATA_CONNECT_TIMEOUT_MS)
                }.isSuccess
            }
            val ok = withTimeoutOrNull(DATA_CONNECT_TIMEOUT_MS + 1_000L) { attempt.await() } ?: false
            if (!ok) {
                attempt.cancel()
                runCatching { s.close() }
                Log.w(TAG, "数据链路 $host:$port 连不上")
                return
            }

            configureTcp(s)
            val link = Link(
                label = "data:$host:$port",
                socket = s,
                input = DataInputStream(s.getInputStream()),
                output = DataOutputStream(s.getOutputStream()),
                isBluetooth = false,
                chunk = dataChunk,
            )
            // 先 HELLO 再 IDENT：手机看到 role=data 才把这条 TCP 挂到蓝牙会话上，不会断蓝牙
            link.send(RelayProtocol.hello(localDeviceName()))
            link.send(RelayProtocol.ident(identJson("tcp", "data")))
            if (controlLink !== control) {      // 蓝牙已断，别把孤儿链路留下
                link.close()
                return
            }

            dataLink = link
            Log.i(TAG, "数据链路已建立 $host:$port")

            readLoop(link)

            if (dataLink === link) dataLink = null
            link.close()
            Log.i(TAG, "数据链路断开 $host:$port")
        } catch (e: CancellationException) {
            runCatching { s.close() }
            throw e
        } catch (e: Exception) {
            runCatching { s.close() }
            Log.w(TAG, "数据链路失败：${e.message}")
        } finally {
            if (dataLink?.socket === s) dataLink = null
        }
    }

    private fun configureTcp(s: java.net.Socket) {
        runCatching {
            s.tcpNoDelay = true
            s.sendBufferSize = 256 * 1024
            s.receiveBufferSize = 256 * 1024
        }
    }

    /** 记住的端点：手机 NET_INFO 下发过，或用户手工填过 */
    private fun savedEndpoint(): Pair<String, Int>? {
        val host = prefs.getString(KEY_WIFI_HOST, null)?.takeIf { it.isNotBlank() } ?: return null
        val port = prefs.getInt(KEY_WIFI_PORT, 0)
        return if (port > 0) host to port else null
    }

    private fun onWifiFailed(host: String, port: Int) {
        wifiFailures += 1
        wifiCooldownUntil = System.currentTimeMillis() + WIFI_COOLDOWN_MS
        Log.w(TAG, "Wi-Fi $host:$port 连不上（第 $wifiFailures 次），回落蓝牙")
        if (wifiFailures >= WIFI_FAILURE_LIMIT) {
            wifiFailures = 0
            prefs.edit().remove(KEY_WIFI_HOST).remove(KEY_WIFI_PORT).apply()
            Log.w(TAG, "Wi-Fi 连续失败，已清除端点记忆")
        }
    }

    /**
     * 手机下发的网络端点：只记下来并唤醒数据链路，绝不断开蓝牙。
     *
     * 新版手机把 role=data 的 TCP 挂到蓝牙会话上，控制仍走蓝牙；
     * 没有可用地址时收掉数据链路，继续走蓝牙。
     */
    private fun onNetInfo(frame: RelayProtocol.Frame, link: Link) {
        val obj = runCatching { JSONObject(String(frame.payload, Charsets.UTF_8)) }.getOrNull() ?: return
        val port = obj.optInt("port", 0)
        val ips = obj.optJSONArray("ips")?.let { arr ->
            (0 until arr.length()).mapNotNull { i ->
                arr.optString(i).takeIf { it.isNotBlank() }
            }
        } ?: emptyList()
        val chunk = obj.optInt("chunk", WIFI_CHUNK)

        if (port <= 0 || ips.isEmpty()) {
            prefs.edit().remove(KEY_WIFI_HOST).remove(KEY_WIFI_PORT).apply()
            if (link.isBluetooth) closeDataLink()
            Log.i(TAG, "手机未提供 Wi-Fi 端点（可能没连 Wi-Fi），继续走蓝牙")
            return
        }
        if (chunk > 0) {
            val size = chunk.coerceIn(RelayProtocol.MAX_CHUNK, 256 * 1024)
            dataChunk = size
            if (!link.isBluetooth) link.chunk = size
        }

        val host = preferLan(ips)
        val saved = savedEndpoint()
        if (saved != null && saved.first == host && saved.second == port) {
            dataWake.trySend(Unit)
            return
        }
        prefs.edit().putString(KEY_WIFI_HOST, host).putInt(KEY_WIFI_PORT, port).apply()
        Log.i(TAG, "手机提供 Wi-Fi 端点 $host:$port，准备建立数据链路")
        if (link.isBluetooth) {
            closeDataLink()     // 端点变了，旧链路作废
            dataWake.trySend(Unit)
        }
    }

    /** 多网卡时优先内网地址 */
    private fun preferLan(ips: List<String>): String {
        ips.firstOrNull { it.startsWith("192.168.") || it.startsWith("10.") }?.let { return it }
        ips.firstOrNull { ip ->
            if (!ip.startsWith("172.")) return@firstOrNull false
            val second = ip.split(".").getOrNull(1)?.toIntOrNull()
            second != null && second in 16..31
        }?.let { return it }
        return ips.first()
    }

    /** IDENT 载荷：Android 拿不到本机蓝牙 MAC，用持久化的 UUID 当稳定标识 */
    private fun identJson(transport: String, role: String? = null): String {
        val json = JSONObject()
            .put("id", localPeerId())
            .put("platform", "android")
            .put("transport", transport)
        localBluetoothMac()?.let { json.put("bt", it) }
        if (role != null) json.put("role", role)
        return json.toString()
    }

    private fun localPeerId(): String {
        prefs.getString(KEY_PEER_ID, null)?.let { return it }
        val id = UUID.randomUUID().toString().replace("-", "")
        prefs.edit().putString(KEY_PEER_ID, id).apply()
        return id
    }

    /**
     * 本机蓝牙 MAC。Android 6 起系统不再对应用公开，能拿到就带上，
     * 手机据此把数据链路挂回对应的蓝牙会话；拿不到只带 id。
     */
    private fun localBluetoothMac(): String? {
        val adapter = bluetoothAdapter()
        runCatching { adapter?.address }.getOrNull()?.let { if (isMac(it)) return it }
        runCatching {
            Settings.Secure.getString(app.contentResolver, "bluetooth_address")
        }.getOrNull()?.let { if (isMac(it)) return it }
        return null
    }

    private fun isMac(value: String?): Boolean =
        value != null && value != "02:00:00:00:00:00" &&
            Regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$").matches(value)

    private suspend fun readLoop(link: Link) {
        val assembler = RelayProtocol.FileAssembler()
        val batch = BatchReceiver()
        try {
            while (true) {
                val frame = RelayProtocol.read(link.input) ?: break
                handleFrame(frame, assembler, batch, link)
            }
        } catch (e: IOException) {
            if (running) Log.i(TAG, "连接断开（${link.label}）：${e.message}")
        } catch (e: SecurityException) {
            Log.w(TAG, "蓝牙权限异常：${e.message}")
        } finally {
            // 半截文件/批次不能留到重连之后
            batch.reset()
            assembler.clear()
        }
    }

    private suspend fun handleFrame(
        frame: RelayProtocol.Frame,
        assembler: RelayProtocol.FileAssembler,
        batch: BatchReceiver,
        link: Link,
    ) {
        when (frame.type) {
            RelayProtocol.FrameType.TEXT -> {
                val text = String(frame.payload, Charsets.UTF_8)
                addRecord(
                    RelayRecord(
                        id = newId(), inbound = true, isFile = false, title = text,
                        text = text, size = frame.payload.size.toLong(),
                        status = RecordStatus.RECEIVED
                    )
                )
                copyText(text)
                Notifier.receivedText(app, text)
                if (frame.needAck) sendFrame(RelayProtocol.ack(frame.type), link)
            }

            RelayProtocol.FrameType.CONFIG -> {
                val json = runCatching { JSONObject(String(frame.payload, Charsets.UTF_8)) }.getOrNull()
                val max = json?.optLong("maxBytes", RelayProtocol.MAX_FILE) ?: RelayProtocol.MAX_FILE
                val value = if (max <= 0L) 0L else max
                _transferLimit.value = value
                assembler.maxBytes = if (value > 0L) value else Long.MAX_VALUE
            }

            RelayProtocol.FrameType.BATCH_META -> {
                handleBatchMeta(frame, assembler, batch, link)
                if (frame.needAck) sendFrame(RelayProtocol.ack(frame.type), link)
            }

            RelayProtocol.FrameType.FILE_META -> {
                if (batch.active) {
                    handleBatchFileMeta(frame, assembler, batch, link)
                } else {
                    val json = runCatching { JSONObject(String(frame.payload, Charsets.UTF_8)) }.getOrNull()
                    val name = json?.optString("name", "file") ?: "file"
                    val size = json?.optLong("size", -1) ?: -1
                    assembler.onMeta(name, size)
                }
            }

            RelayProtocol.FrameType.FILE_CHUNK -> if (!batch.discarding) assembler.onChunk(frame.payload)

            RelayProtocol.FrameType.FILE_END -> {
                if (batch.active) {
                    handleBatchFileEnd(assembler, batch, link)
                } else {
                    val name = assembler.name
                    if (assembler.overflow) {
                        emitMessage(app.getString(R.string.msg_file_exceeds_limit_ignored, name, limitLabel()))
                    } else {
                        val mime = mimeOf(name)
                        val saved = saveDownload(name, assembler.bytes())
                        if (saved != null) {
                            addRecord(
                                RelayRecord(
                                    id = newId(), inbound = true, isFile = true, title = name,
                                    uri = saved, mime = mime, size = assembler.received,
                                    status = RecordStatus.RECEIVED
                                )
                            )
                            Notifier.receivedFile(app, name, saved, mime)
                        } else {
                            emitMessage(app.getString(R.string.msg_file_save_failed, name))
                        }
                    }
                    assembler.clear()
                }
                if (frame.needAck) sendFrame(RelayProtocol.ack(frame.type), link)
            }

            RelayProtocol.FrameType.BATCH_END -> {
                handleBatchEnd(batch)
                if (frame.needAck) sendFrame(RelayProtocol.ack(frame.type), link)
            }

            RelayProtocol.FrameType.PING -> sendFrame(RelayProtocol.pong(), link)

            // 手机下发的网络端点：只记下来并唤醒数据链路，绝不断开蓝牙
            RelayProtocol.FrameType.NET_INFO -> onNetInfo(frame, link)

            RelayProtocol.FrameType.ERROR -> {
                emitMessage(app.getString(R.string.msg_phone_error, String(frame.payload, Charsets.UTF_8)))
            }
        }
    }

    private suspend fun handleBatchMeta(
        frame: RelayProtocol.Frame,
        assembler: RelayProtocol.FileAssembler,
        batch: BatchReceiver,
        link: Link,
    ) {
        val json = runCatching { JSONObject(String(frame.payload, Charsets.UTF_8)) }.getOrNull()
        if (json == null) {
            emitMessage(app.getString(R.string.msg_batch_parse_error))
            return
        }
        val rawName = json.optString("name", app.getString(R.string.folder_default_name)).ifBlank { app.getString(R.string.folder_default_name) }
        val dirs = json.optJSONArray("dirs")?.let { array ->
            (0 until array.length()).mapNotNull { i ->
                array.optString(i).takeIf { it.isNotBlank() }
            }
        } ?: emptyList()
        batch.start(
            id = json.optString("id", ""),
            folder = uniqueFolderName(sanitizeName(rawName)),
            files = json.optInt("files", 0),
            bytes = json.optLong("bytes", 0),
            dirs = dirs
        )
        assembler.clear()

        val limit = _transferLimit.value
        if (limit > 0L && batch.declaredBytes > limit) {
            batch.rejected = true
            emitMessage(app.getString(R.string.msg_folder_exceeds_limit, rawName))
            sendFrame(RelayProtocol.error(app.getString(R.string.msg_folder_exceeds_limit, limitLabel())), link)
        }
    }

    private suspend fun handleBatchFileMeta(
        frame: RelayProtocol.Frame,
        assembler: RelayProtocol.FileAssembler,
        batch: BatchReceiver,
        link: Link,
    ) {
        val json = runCatching { JSONObject(String(frame.payload, Charsets.UTF_8)) }.getOrNull()
        if (json == null) {
            batch.strayFile = true
            emitMessage(app.getString(R.string.msg_batch_file_parse_error))
            return
        }
        batch.strayFile = false
        if (batch.rejected) {
            batch.strayFile = true
            return
        }
        val path = json.optString("path", "").ifBlank { json.optString("name", "file") }
        val size = json.optLong("size", -1)
        val batchId = json.optString("batch", "")
        if (batchId.isNotEmpty() && batchId != batch.id) {
            batch.strayFile = true
            emitMessage(app.getString(R.string.msg_batch_id_mismatch, path))
            return
        }

        val limit = _transferLimit.value
        if (size > 0L && !withinLimit(size)) {
            batch.rejected = true
            emitMessage(app.getString(R.string.msg_file_exceeds_limit_batch, limitLabel()))
            sendFrame(RelayProtocol.error(app.getString(R.string.msg_file_exceeds_limit_batch, limitLabel())), link)
            return
        }
        if (limit > 0L && size > 0L && batch.receivedBytes + size > limit) {
            batch.rejected = true
            emitMessage(app.getString(R.string.msg_folder_exceeds_limit_batch, limitLabel()))
            sendFrame(RelayProtocol.error(app.getString(R.string.msg_folder_exceeds_limit_batch, limitLabel())), link)
            return
        }

        batch.currentPath = sanitizeRelativePath(path)
        assembler.onMeta(path.substringAfterLast('/').ifBlank { "file" }, size)
    }

    private suspend fun handleBatchFileEnd(
        assembler: RelayProtocol.FileAssembler,
        batch: BatchReceiver,
        link: Link,
    ) {
        if (batch.discarding) {
            assembler.clear()
            batch.strayFile = false
            return
        }
        if (assembler.overflow) {
            batch.rejected = true
            emitMessage(app.getString(R.string.msg_file_exceeds_limit_batch, limitLabel()))
            sendFrame(RelayProtocol.error(app.getString(R.string.msg_file_exceeds_limit_batch, limitLabel())), link)
            assembler.clear()
            return
        }
        val limit = _transferLimit.value
        if (limit > 0L && batch.receivedBytes + assembler.received > limit) {
            batch.rejected = true
            emitMessage(app.getString(R.string.msg_folder_exceeds_limit_batch, limitLabel()))
            sendFrame(RelayProtocol.error(app.getString(R.string.msg_folder_exceeds_limit_batch, limitLabel())), link)
            assembler.clear()
            return
        }

        val path = batch.currentPath.ifBlank { sanitizeRelativePath(assembler.name) }
        val saved = saveBatchFile(batch.basePath, path, assembler.bytes())
        if (saved != null) {
            batch.receivedBytes += assembler.received
            batch.receivedFiles += 1
            if (batch.firstUri == null) batch.firstUri = saved
        } else {
            emitMessage(app.getString(R.string.msg_file_save_failed, assembler.name))
        }
        assembler.clear()
    }

    private fun handleBatchEnd(batch: BatchReceiver) {
        if (!batch.active) return
        if (!batch.rejected) {
            val count = if (batch.receivedFiles > 0) batch.receivedFiles else batch.expectedFiles
            addRecord(
                RelayRecord(
                    id = newId(), inbound = true, isFile = true,
                    title = app.getString(R.string.folder_record_title, batch.name, count),
                    uri = batch.firstUri, size = batch.receivedBytes,
                    status = RecordStatus.RECEIVED
                )
            )
            Notifier.receivedFolder(app, batch.name, count, batch.firstUri)
        } else {
            emitMessage(app.getString(R.string.msg_folder_discarded, batch.name))
        }
        batch.reset()
    }

    // ------------------------------------------------------------
    // 发送队列
    // ------------------------------------------------------------

    private fun ensureWorker() {
        if (workerJob?.isActive == true) return
        workerJob = scope.launch {
            for (task in outgoing) {
                // 未连接时原地等待，连上后再发，行为与 PC 端的待发队列一致
                while (controlLink == null && dataLink == null) delay(200)
                when (task) {
                    is Outgoing.TextTask -> deliverText(task)
                    is Outgoing.FileTask -> deliverFile(task)
                    is Outgoing.TreeTask -> deliverTree(task)
                }
            }
        }
    }

    /** TEXT 始终走蓝牙控制链路 */
    private suspend fun deliverText(task: Outgoing.TextTask) {
        updateRecord(task.recordId) { it.copy(status = RecordStatus.SENDING) }
        try {
            sendFrame(RelayProtocol.text(task.text))
            updateRecord(task.recordId) { it.copy(status = RecordStatus.SENT) }
        } catch (e: Exception) {
            updateRecord(task.recordId) { it.copy(status = RecordStatus.FAILED) }
            emitMessage(app.getString(R.string.msg_send_failed, e.message ?: app.getString(R.string.msg_send_connection_closed)))
        }
    }

    /**
     * 发送前等数据链路就绪：手机刚下发 NET_INFO 时 TCP 还在建立，
     * 直接发会落到蓝牙。给 TCP 3 秒优先窗口，等不到才兜底。
     */
    private suspend fun awaitDataLink(): Link? {
        dataLink?.let { return it }
        if (controlLink == null || savedEndpoint() == null) return null
        if (System.currentTimeMillis() < dataLinkWaitSkippedUntil) return null
        val deadline = System.currentTimeMillis() + 3_000
        while (System.currentTimeMillis() < deadline) {
            delay(100)
            dataLink?.let { return it }
        }
        dataLinkWaitSkippedUntil = System.currentTimeMillis() + 30_000
        Log.i(TAG, "数据链路未就绪，本次文件改走蓝牙")
        return null
    }

    /** 文件数据链路在线就走数据链路，否则走蓝牙控制链路 */
    private suspend fun deliverFile(task: Outgoing.FileTask) {
        fileMutex.withLock {
            updateRecord(task.recordId) { it.copy(status = RecordStatus.SENDING) }
            val link = awaitDataLink() ?: controlLink
            try {
                if (link == null) throw IOException(app.getString(R.string.error_not_connected))
                val chunk = link.chunk
                val bytes = task.file.readBytes()
                if (!withinLimit(bytes.size.toLong())) throw IOException("超过传输上限")
                val meta = JSONObject()
                    .put("name", task.name)
                    .put("size", bytes.size)
                    .toString()
                sendFrame(RelayProtocol.fileMeta(meta), link)
                var off = 0
                while (off < bytes.size) {
                    val len = minOf(chunk, bytes.size - off)
                    sendFrame(RelayProtocol.chunk(bytes, off, len), link)
                    off += len
                }
                sendFrame(RelayProtocol.fileEnd(), link)
                updateRecord(task.recordId) { it.copy(status = RecordStatus.SENT) }
            } catch (e: Exception) {
                updateRecord(task.recordId) { it.copy(status = RecordStatus.FAILED) }
                emitMessage(app.getString(R.string.msg_file_send_failed, task.name))
                Log.w(TAG, "发送文件失败", e)
            } finally {
                runCatching { task.file.delete() }
            }
        }
    }

    /** 文件夹发送：BATCH_META → 逐文件流式发送 → BATCH_END，与单文件共用 fileMutex */
    private suspend fun deliverTree(task: Outgoing.TreeTask) {
        fileMutex.withLock {
            updateRecord(task.recordId) { it.copy(status = RecordStatus.SENDING) }
            val link = awaitDataLink() ?: controlLink
            var sentBytes = 0L
            try {
                if (link == null) throw IOException(app.getString(R.string.error_not_connected))
                val chunk = link.chunk
                val limit = _transferLimit.value
                val meta = JSONObject()
                    .put("id", task.recordId)
                    .put("name", task.name)
                    .put("files", task.files.size)
                    .put("bytes", task.totalBytes)
                    .put("dirs", JSONArray(task.dirs))
                    .toString()
                sendFrame(RelayProtocol.batchMeta(meta), link)

                for (entry in task.files) {
                    val fileName = entry.path.substringAfterLast('/')
                    sendFrame(RelayProtocol.fileMeta(fileName, entry.size, entry.path, task.recordId), link)
                    val input = app.contentResolver.openInputStream(entry.uri)
                        ?: throw IOException("无法读取 ${entry.path}")
                    input.use { stream ->
                        val buffer = ByteArray(chunk)
                        while (true) {
                            val read = stream.read(buffer)
                            if (read < 0) break
                            if (read == 0) continue
                            if (limit > 0L && sentBytes + read > limit) throw IOException("超过传输上限")
                            sendFrame(RelayProtocol.chunk(buffer, 0, read), link)
                            sentBytes += read
                        }
                    }
                    sendFrame(RelayProtocol.fileEnd(), link)
                }

                val end = JSONObject()
                    .put("id", task.recordId)
                    .put("files", task.files.size)
                    .toString()
                sendFrame(RelayProtocol.batchEnd(end), link)
                updateRecord(task.recordId) { it.copy(status = RecordStatus.SENT) }
            } catch (e: Exception) {
                updateRecord(task.recordId) { it.copy(status = RecordStatus.FAILED) }
                emitMessage(app.getString(R.string.msg_folder_send_failed, task.name))
                Log.w(TAG, "发送文件夹失败", e)
            }
        }
    }

    /** 没有指定通道时走蓝牙控制链路；这条消息会被 deliverText 拼进 msg_send_failed 直接展示，必须本地化 */
    private suspend fun sendFrame(frame: RelayProtocol.Frame, link: Link? = null) {
        val target = link ?: controlLink
            ?: throw IOException(app.getString(R.string.error_not_connected))
        target.send(frame)
    }

    // ------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------

    private fun bluetoothAdapter(): BluetoothAdapter? {
        if (!::app.isInitialized) return null
        val manager = app.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter
    }

    private fun hasConnectPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    private fun findBlueDeskDevice(adapter: BluetoothAdapter): BluetoothDevice? = runCatching {
        adapter.bondedDevices.orEmpty()
            .firstOrNull { device -> deviceNameSafe(device)?.startsWith("BlueDesk", true) == true }
    }.getOrNull()

    private fun deviceNameSafe(device: BluetoothDevice): String? =
        runCatching { device.name }.getOrNull()?.takeIf { it.isNotBlank() }

    private fun localDeviceName(): String =
        (Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android").let { "Android $it" }

    private fun friendlyError(e: Exception): String = when (e) {
        is SecurityException -> app.getString(R.string.state_error_no_bluetooth_permission)
        is IOException -> e.message ?: app.getString(R.string.error_connection_failed)
        else -> e.message ?: app.getString(R.string.error_connection_failed)
    }

    private fun closeDataLink() {
        val link = dataLink
        dataLink = null
        link?.close()
    }

    /** 关掉控制链路与挂在它上面的数据链路；蓝牙控制断开时数据链路必须一起收掉 */
    private fun closeLinks() {
        closeDataLink()
        runCatching { pendingSocket?.close() }
        pendingSocket = null
        val link = controlLink
        controlLink = null
        link?.close()
    }

    private fun addRecord(record: RelayRecord) {
        _records.update { (listOf(record) + it).take(200) }
    }

    private fun updateRecord(id: String, transform: (RelayRecord) -> RelayRecord) {
        _records.update { list -> list.map { if (it.id == id) transform(it) else it } }
    }

    private fun emitMessage(message: String) {
        _messages.tryEmit(message)
    }

    private fun newId(): String = UUID.randomUUID().toString().take(8)

    private fun copyText(text: String) {
        Handler(Looper.getMainLooper()).post {
            val manager = app.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            runCatching { manager?.setPrimaryClip(ClipData.newPlainText("BlueDesk", text)) }
        }
    }

    private fun queryMeta(uri: Uri): FileMetaInfo {
        var name = uri.lastPathSegment ?: "file"
        var size = -1L
        runCatching {
            app.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                }
            }
        }
        if (size < 0) {
            size = runCatching {
                app.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
            }.getOrNull() ?: -1L
        }
        return FileMetaInfo(name, size)
    }

    private fun copyToCache(uri: Uri, name: String): File? {
        val dir = File(app.cacheDir, "outgoing").apply { mkdirs() }
        val target = uniqueFile(dir, sanitizeName(name))
        return try {
            val input = app.contentResolver.openInputStream(uri) ?: return null
            input.use { source -> target.outputStream().use { source.copyTo(it) } }
            target
        } catch (e: Exception) {
            runCatching { target.delete() }
            Log.w(TAG, "复制到缓存失败", e)
            null
        }
    }

    private fun saveDownload(name: String, bytes: ByteArray): Uri? {
        val resolver = app.contentResolver
        val display = sanitizeName(name)
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, display)
            put(MediaStore.Downloads.MIME_TYPE, mimeOf(display))
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/BlueDesk")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = runCatching {
            resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        }.getOrNull() ?: return null
        return try {
            val stream = resolver.openOutputStream(uri) ?: throw IOException("无法打开输出流")
            stream.use { it.write(bytes) }
            val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
            uri
        } catch (e: Exception) {
            Log.w(TAG, "保存文件失败", e)
            runCatching { resolver.delete(uri, null, null) }
            null
        }
    }

    private fun saveBatchFile(basePath: String, relativePath: String, bytes: ByteArray): Uri? {
        val segments = relativePath.split('/').filter { it.isNotBlank() }
        val fileName = sanitizeName(segments.lastOrNull() ?: "file")
        val subDir = segments.dropLast(1).joinToString("/")
        val relativeDir = if (subDir.isBlank()) basePath else "$basePath/$subDir"
        val display = uniqueDownloadName(relativeDir, fileName)
        val resolver = app.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, display)
            put(MediaStore.Downloads.MIME_TYPE, mimeOf(display))
            put(MediaStore.Downloads.RELATIVE_PATH, relativeDir)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = runCatching {
            resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        }.getOrNull() ?: return null
        return try {
            val stream = resolver.openOutputStream(uri) ?: throw IOException("无法打开输出流")
            stream.use { it.write(bytes) }
            val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
            uri
        } catch (e: Exception) {
            Log.w(TAG, "保存批次文件失败", e)
            runCatching { resolver.delete(uri, null, null) }
            null
        }
    }

    /** 下载目录内同名文件自动加 (1)、(2)… */
    private fun uniqueDownloadName(relativeDir: String, name: String): String {
        if (!downloadNameExists(relativeDir, name)) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var index = 1
        while (index < 10000) {
            val candidate = "$base($index)$ext"
            if (!downloadNameExists(relativeDir, candidate)) return candidate
            index++
        }
        return "$base($index)$ext"
    }

    private fun downloadNameExists(relativeDir: String, name: String): Boolean {
        val base = relativeDir.trimEnd('/')
        val selection = "(${MediaStore.MediaColumns.RELATIVE_PATH} = ? OR " +
            "${MediaStore.MediaColumns.RELATIVE_PATH} = ?) AND " +
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ?"
        return runCatching {
            app.contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.MediaColumns._ID),
                selection, arrayOf(base, "$base/", name), null
            )?.use { it.count > 0 } ?: false
        }.getOrDefault(false)
    }

    /** Download/BlueDesk 下是否已有该文件夹（含其内容/子目录） */
    private fun downloadFolderExists(folder: String): Boolean {
        val base = "Download/BlueDesk/$folder"
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} = ? OR " +
            "${MediaStore.MediaColumns.RELATIVE_PATH} = ? OR " +
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
        return runCatching {
            app.contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.MediaColumns._ID),
                selection, arrayOf(base, "$base/", "$base/%"), null
            )?.use { it.count > 0 } ?: false
        }.getOrDefault(false)
    }

    private fun uniqueFolderName(base: String): String {
        if (!downloadFolderExists(base)) return base
        var index = 1
        while (index < 1000) {
            val candidate = "$base($index)"
            if (!downloadFolderExists(candidate)) return candidate
            index++
        }
        return "$base($index)"
    }

    private fun sanitizeRelativePath(path: String): String {
        val segments = path.replace('\\', '/').split('/')
            .filter { it.isNotBlank() }
            .map { sanitizeName(it) }
        return if (segments.isEmpty()) "file" else segments.joinToString("/")
    }

    private fun withinLimit(size: Long): Boolean {
        val limit = _transferLimit.value
        return size < 0L || limit <= 0L || size <= limit
    }

    private fun limitLabel(): String {
        val limit = _transferLimit.value
        if (limit <= 0L) return app.getString(R.string.limit_unlimited)
        val mb = 1024L * 1024L
        return when {
            limit >= mb && limit % mb == 0L -> "${limit / mb} MB"
            limit >= mb -> String.format(Locale.US, "%.1f MB", limit / mb.toDouble())
            limit % 1024L == 0L -> "${limit / 1024L} KB"
            else -> "${limit} B"
        }
    }

    private fun sanitizeName(name: String): String {
        val cleaned = name.replace(Regex("[\\\\/:*?\"<>|\\n\\r]"), "_").trim()
        return cleaned.ifBlank { "file" }.take(120)
    }

    private fun uniqueFile(dir: File, name: String): File {
        var file = File(dir, name)
        if (!file.exists()) return file
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var index = 1
        while (file.exists()) {
            file = File(dir, "$base(${index++})$ext")
        }
        return file
    }

    private fun mimeOf(name: String): String {
        val dot = name.lastIndexOf('.')
        if (dot >= 0 && dot < name.length - 1) {
            val ext = name.substring(dot + 1).lowercase(Locale.US)
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)?.let { return it }
        }
        return "application/octet-stream"
    }
}
