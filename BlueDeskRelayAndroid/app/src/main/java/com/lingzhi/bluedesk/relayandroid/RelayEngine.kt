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
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.UUID

/** 连接状态（UI、通知、引擎共用） */
sealed interface ConnState {
    data object Idle : ConnState
    data object BluetoothOff : ConnState
    data object NoDevice : ConnState
    data class Connecting(val name: String) : ConnState
    data class Connected(val name: String, val address: String) : ConnState
    data class Error(val message: String) : ConnState
}

fun ConnState.describe(): String = when (this) {
    ConnState.Idle -> "等待连接"
    ConnState.BluetoothOff -> "蓝牙未开启"
    ConnState.NoDevice -> "未找到已配对的 BlueDesk 手机"
    is ConnState.Connecting -> "正在连接 $name…"
    is ConnState.Connected -> "已连接 $name"
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
 *  - 收 TEXT → 写剪贴板并通知；收 FILE_META/CHUNK/END → 存 Download/BlueDesk；
 *  - 收到的 needAck 帧回 ACK，PING 回 PONG；
 *  - 断线每 5 秒自动重连；发送内容在未连接时排队。
 */
object RelayEngine {

    private const val TAG = "RelayEngine"
    private const val PREFS = "relay_prefs"
    private const val KEY_MAC = "peer_mac"
    private const val KEY_NAME = "peer_name"
    private const val RETRY_MS = 5_000L
    private const val CONNECT_TIMEOUT_MS = 15_000L

    private lateinit var app: Context
    private lateinit var prefs: SharedPreferences

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val writeMutex = Mutex()
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

    @Volatile
    private var socket: BluetoothSocket? = null

    @Volatile
    private var pendingSocket: BluetoothSocket? = null

    @Volatile
    private var output: DataOutputStream? = null

    private var supervisorJob: Job? = null
    private var workerJob: Job? = null

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

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        Notifier.init(app)
        ensureWorker()
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
    }

    fun stop() {
        running = false
        supervisorJob?.cancel()
        supervisorJob = null
        closeSocket()
        _state.value = ConnState.Idle
    }

    fun disconnect() {
        paused = true
        closeSocket()
        _state.value = ConnState.Idle
    }

    fun reconnect() {
        paused = false
        wake.trySend(Unit)
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
                        emitMessage("${meta.name} 超过传输上限（${limitLabel()}），未发送")
                        continue
                    }
                    val cached = copyToCache(uri, meta.name)
                    if (cached == null) {
                        emitMessage("无法读取 ${meta.name}")
                        continue
                    }
                    if (!withinLimit(cached.length())) {
                        cached.delete()
                        emitMessage("${meta.name} 超过传输上限（${limitLabel()}），未发送")
                        continue
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
                    emitMessage("读取文件失败：${e.message ?: "未知错误"}")
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
                    emitMessage("无法读取所选文件夹")
                    return@launch
                }
                val files = mutableListOf<TreeEntry>()
                val dirs = mutableListOf<String>()
                collectTree(root, "", files, dirs)
                if (files.isEmpty() && dirs.isEmpty()) {
                    emitMessage("所选文件夹为空，未发送")
                    return@launch
                }
                // SAF 可能返回 -1（大小未知），声明总量只统计已知大小；
                // 未知部分由发送时的累计字节数与手机端累计校验兜底。
                val total = files.sumOf { if (it.size >= 0L) it.size else 0L }
                if (!withinLimit(total)) {
                    emitMessage("文件夹超过传输上限（${limitLabel()}），未发送")
                    return@launch
                }
                val rawName = root.name?.takeIf { it.isNotBlank() } ?: "文件夹"
                val name = sanitizeName(rawName)
                val id = newId()
                addRecord(
                    RelayRecord(
                        id = id, inbound = false, isFile = true,
                        title = "文件夹 $name（${files.size} 个文件）",
                        size = total, status = RecordStatus.QUEUED
                    )
                )
                outgoing.send(Outgoing.TreeTask(id, name, files, dirs, total))
            } catch (e: Exception) {
                Log.w(TAG, "读取待发送文件夹失败", e)
                emitMessage("读取文件夹失败：${e.message ?: "未知错误"}")
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
                if (socket != null) {
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
                if (running && socket == null) {
                    withTimeoutOrNull(RETRY_MS) { wake.receive() }
                }
            }
        }
    }

    private suspend fun connectOnce() = withContext(Dispatchers.IO) {
        val adapter = bluetoothAdapter()
        if (adapter == null) {
            _state.value = ConnState.Error("这台设备不支持蓝牙")
            return@withContext
        }
        if (!hasConnectPermission()) {
            _state.value = ConnState.Error("缺少「附近的设备」权限")
            return@withContext
        }
        if (!runCatching { adapter.isEnabled }.getOrDefault(false)) {
            _state.value = ConnState.BluetoothOff
            return@withContext
        }

        val savedMac = prefs.getString(KEY_MAC, null)
        val device = savedMac?.let { mac -> runCatching { adapter.getRemoteDevice(mac) }.getOrNull() }
            ?: findBlueDeskDevice(adapter)
        if (device == null) {
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
                throw IOException("无法连接，请确认手机端已开启互传服务")
            }

            pendingSocket = null
            val input = DataInputStream(s.inputStream)
            val out = DataOutputStream(s.outputStream)
            socket = s
            output = out
            sendFrame(RelayProtocol.hello(localDeviceName()))

            prefs.edit().putString(KEY_MAC, device.address).putString(KEY_NAME, name).apply()
            _state.value = ConnState.Connected(name, device.address)
            Log.i(TAG, "已连接 $name (${device.address})")
            readLoop(input)
        } catch (e: CancellationException) {
            runCatching { connecting?.close() }
            throw e
        } catch (e: Exception) {
            runCatching { connecting?.close() }
            if (socket == null) {
                _state.value = ConnState.Error(friendlyError(e))
                Log.w(TAG, "连接失败：${e.message}")
            }
        } finally {
            pendingSocket = null
        }
    }

    private suspend fun readLoop(input: DataInputStream) {
        val assembler = RelayProtocol.FileAssembler()
        val batch = BatchReceiver()
        try {
            while (true) {
                val frame = RelayProtocol.read(input) ?: break
                handleFrame(frame, assembler, batch)
            }
        } catch (e: IOException) {
            if (running) Log.i(TAG, "连接断开：${e.message}")
        } catch (e: SecurityException) {
            Log.w(TAG, "蓝牙权限异常：${e.message}")
        } finally {
            batch.reset()
            closeSocket()
            if (running) _state.value = ConnState.Idle
        }
    }

    private suspend fun handleFrame(
        frame: RelayProtocol.Frame,
        assembler: RelayProtocol.FileAssembler,
        batch: BatchReceiver,
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
                if (frame.needAck) sendFrame(RelayProtocol.ack(frame.type))
            }

            RelayProtocol.FrameType.CONFIG -> {
                val json = runCatching { JSONObject(String(frame.payload, Charsets.UTF_8)) }.getOrNull()
                val max = json?.optLong("maxBytes", RelayProtocol.MAX_FILE) ?: RelayProtocol.MAX_FILE
                val value = if (max <= 0L) 0L else max
                _transferLimit.value = value
                assembler.maxBytes = if (value > 0L) value else Long.MAX_VALUE
            }

            RelayProtocol.FrameType.BATCH_META -> {
                handleBatchMeta(frame, assembler, batch)
                if (frame.needAck) sendFrame(RelayProtocol.ack(frame.type))
            }

            RelayProtocol.FrameType.FILE_META -> {
                if (batch.active) {
                    handleBatchFileMeta(frame, assembler, batch)
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
                    handleBatchFileEnd(assembler, batch)
                } else {
                    val name = assembler.name
                    if (assembler.overflow) {
                        emitMessage("$name 超过传输上限（${limitLabel()}），已忽略")
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
                            emitMessage("文件保存失败：$name")
                        }
                    }
                    assembler.clear()
                }
                if (frame.needAck) sendFrame(RelayProtocol.ack(frame.type))
            }

            RelayProtocol.FrameType.BATCH_END -> {
                handleBatchEnd(batch)
                if (frame.needAck) sendFrame(RelayProtocol.ack(frame.type))
            }

            RelayProtocol.FrameType.PING -> sendFrame(RelayProtocol.pong())

            RelayProtocol.FrameType.ERROR -> {
                emitMessage("手机端提示：${String(frame.payload, Charsets.UTF_8)}")
            }
        }
    }

    private suspend fun handleBatchMeta(
        frame: RelayProtocol.Frame,
        assembler: RelayProtocol.FileAssembler,
        batch: BatchReceiver,
    ) {
        val json = runCatching { JSONObject(String(frame.payload, Charsets.UTF_8)) }.getOrNull()
        if (json == null) {
            emitMessage("批次信息无法解析")
            return
        }
        val rawName = json.optString("name", "文件夹").ifBlank { "文件夹" }
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
            emitMessage("文件夹 $rawName 超过传输上限（${limitLabel()}），已丢弃")
            sendFrame(RelayProtocol.error("文件夹超过传输上限"))
        }
    }

    private suspend fun handleBatchFileMeta(
        frame: RelayProtocol.Frame,
        assembler: RelayProtocol.FileAssembler,
        batch: BatchReceiver,
    ) {
        val json = runCatching { JSONObject(String(frame.payload, Charsets.UTF_8)) }.getOrNull()
        if (json == null) {
            batch.strayFile = true
            emitMessage("批次文件信息无法解析")
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
            emitMessage("批次 id 不匹配，已忽略 $path")
            return
        }

        val limit = _transferLimit.value
        if (size > 0L && !withinLimit(size)) {
            batch.rejected = true
            emitMessage("文件超过传输上限（${limitLabel()}），批次已丢弃")
            sendFrame(RelayProtocol.error("文件超过传输上限"))
            return
        }
        if (limit > 0L && size > 0L && batch.receivedBytes + size > limit) {
            batch.rejected = true
            emitMessage("文件夹超过传输上限（${limitLabel()}），批次已丢弃")
            sendFrame(RelayProtocol.error("文件夹超过传输上限"))
            return
        }

        batch.currentPath = sanitizeRelativePath(path)
        assembler.onMeta(path.substringAfterLast('/').ifBlank { "file" }, size)
    }

    private suspend fun handleBatchFileEnd(
        assembler: RelayProtocol.FileAssembler,
        batch: BatchReceiver,
    ) {
        if (batch.discarding) {
            assembler.clear()
            batch.strayFile = false
            return
        }
        if (assembler.overflow) {
            batch.rejected = true
            emitMessage("文件超过传输上限（${limitLabel()}），批次已丢弃")
            sendFrame(RelayProtocol.error("文件超过传输上限"))
            assembler.clear()
            return
        }
        val limit = _transferLimit.value
        if (limit > 0L && batch.receivedBytes + assembler.received > limit) {
            batch.rejected = true
            emitMessage("文件夹超过传输上限（${limitLabel()}），批次已丢弃")
            sendFrame(RelayProtocol.error("文件夹超过传输上限"))
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
            emitMessage("文件保存失败：${assembler.name}")
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
                    title = "文件夹 ${batch.name}（$count 个文件）",
                    uri = batch.firstUri, size = batch.receivedBytes,
                    status = RecordStatus.RECEIVED
                )
            )
            Notifier.receivedFolder(app, batch.name, count, batch.firstUri)
        } else {
            emitMessage("文件夹 ${batch.name} 已丢弃")
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
                while (socket == null) delay(200)
                when (task) {
                    is Outgoing.TextTask -> deliverText(task)
                    is Outgoing.FileTask -> deliverFile(task)
                    is Outgoing.TreeTask -> deliverTree(task)
                }
            }
        }
    }

    private suspend fun deliverText(task: Outgoing.TextTask) {
        updateRecord(task.recordId) { it.copy(status = RecordStatus.SENDING) }
        try {
            sendFrame(RelayProtocol.text(task.text))
            updateRecord(task.recordId) { it.copy(status = RecordStatus.SENT) }
        } catch (e: Exception) {
            updateRecord(task.recordId) { it.copy(status = RecordStatus.FAILED) }
            emitMessage("发送失败：${e.message ?: "连接已断开"}")
        }
    }

    private suspend fun deliverFile(task: Outgoing.FileTask) {
        fileMutex.withLock {
            updateRecord(task.recordId) { it.copy(status = RecordStatus.SENDING) }
            try {
                val bytes = task.file.readBytes()
                if (!withinLimit(bytes.size.toLong())) throw IOException("超过传输上限")
                val meta = JSONObject()
                    .put("name", task.name)
                    .put("size", bytes.size)
                    .toString()
                sendFrame(RelayProtocol.fileMeta(meta))
                var off = 0
                while (off < bytes.size) {
                    val len = minOf(RelayProtocol.MAX_CHUNK, bytes.size - off)
                    sendFrame(RelayProtocol.chunk(bytes, off, len))
                    off += len
                }
                sendFrame(RelayProtocol.fileEnd())
                updateRecord(task.recordId) { it.copy(status = RecordStatus.SENT) }
            } catch (e: Exception) {
                updateRecord(task.recordId) { it.copy(status = RecordStatus.FAILED) }
                emitMessage("文件发送失败：${task.name}")
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
            var sentBytes = 0L
            try {
                val limit = _transferLimit.value
                val meta = JSONObject()
                    .put("id", task.recordId)
                    .put("name", task.name)
                    .put("files", task.files.size)
                    .put("bytes", task.totalBytes)
                    .put("dirs", JSONArray(task.dirs))
                    .toString()
                sendFrame(RelayProtocol.batchMeta(meta))

                for (entry in task.files) {
                    val fileName = entry.path.substringAfterLast('/')
                    sendFrame(RelayProtocol.fileMeta(fileName, entry.size, entry.path, task.recordId))
                    val input = app.contentResolver.openInputStream(entry.uri)
                        ?: throw IOException("无法读取 ${entry.path}")
                    input.use { stream ->
                        val buffer = ByteArray(RelayProtocol.MAX_CHUNK)
                        while (true) {
                            val read = stream.read(buffer)
                            if (read < 0) break
                            if (read == 0) continue
                            if (limit > 0L && sentBytes + read > limit) throw IOException("超过传输上限")
                            sendFrame(RelayProtocol.chunk(buffer, 0, read))
                            sentBytes += read
                        }
                    }
                    sendFrame(RelayProtocol.fileEnd())
                }

                val end = JSONObject()
                    .put("id", task.recordId)
                    .put("files", task.files.size)
                    .toString()
                sendFrame(RelayProtocol.batchEnd(end))
                updateRecord(task.recordId) { it.copy(status = RecordStatus.SENT) }
            } catch (e: Exception) {
                updateRecord(task.recordId) { it.copy(status = RecordStatus.FAILED) }
                emitMessage("文件夹发送失败：${task.name}")
                Log.w(TAG, "发送文件夹失败", e)
            }
        }
    }

    private suspend fun sendFrame(frame: RelayProtocol.Frame) {
        val out = output ?: throw IOException("未连接")
        writeMutex.withLock { RelayProtocol.write(out, frame) }
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
        is SecurityException -> "缺少蓝牙权限"
        is IOException -> e.message ?: "连接失败"
        else -> e.message ?: "连接失败（${e.javaClass.simpleName}）"
    }

    private fun closeSocket() {
        runCatching { pendingSocket?.close() }
        pendingSocket = null
        runCatching { socket?.close() }
        socket = null
        output = null
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
        if (limit <= 0L) return "不限"
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
