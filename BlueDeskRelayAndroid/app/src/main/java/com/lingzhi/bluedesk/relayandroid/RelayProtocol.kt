package com.lingzhi.bluedesk.relayandroid

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.util.UUID
import java.util.zip.CRC32

/**
 * BlueDesk 中转协议 —— 与手机端 app 的 TransferProtocol 逐字节一致。
 *
 * 11 字节定长头 + 载荷：
 * 0..1 MAGIC(0xBD 0x54)、2 VER=1、3 TYPE、4 FLAGS、
 * 5..8 载荷长度（大端 u32）、9..10 CRC32 低 16 位。
 */
object RelayProtocol {

    private const val MAGIC_A = 0xBD
    private const val MAGIC_B = 0x54
    private const val VERSION = 1

    const val HEADER_SIZE = 11
    const val MAX_CHUNK = 4 * 1024

    /** 默认传输上限（64MB）；运行时上限由手机端 CONFIG 下发，0 表示不限 */
    const val MAX_FILE = 64L * 1024 * 1024

    /** 与手机端一致的自定义 SPP 服务 UUID */
    val SERVICE_UUID: UUID = UUID.fromString("a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1")

    object FrameType {
        const val HELLO = 0x01
        const val TEXT = 0x02
        const val FILE_META = 0x03
        const val FILE_CHUNK = 0x04
        const val FILE_END = 0x05
        const val ACK = 0x06
        const val PING = 0x07
        const val PONG = 0x08
        const val ERROR = 0x09
        const val CONFIG = 0x0A
        const val BATCH_META = 0x0B
        const val BATCH_END = 0x0C
    }

    private const val FLAG_NEED_ACK = 0x01

    data class Frame(val type: Int, val payload: ByteArray, val needAck: Boolean = false)

    @Throws(IOException::class)
    fun write(out: DataOutputStream, frame: Frame) {
        val crc = if (frame.payload.isEmpty()) 0xFFFF else {
            val c = CRC32().apply { update(frame.payload) }
            (c.value and 0xFFFF).toInt()
        }
        val head = ByteArray(HEADER_SIZE)
        head[0] = MAGIC_A.toByte()
        head[1] = MAGIC_B.toByte()
        head[2] = VERSION.toByte()
        head[3] = frame.type.toByte()
        head[4] = (if (frame.needAck) FLAG_NEED_ACK else 0).toByte()
        for (i in 0 until 4) {
            head[5 + i] = (frame.payload.size ushr ((3 - i) * 8)).toByte()
        }
        head[9] = (crc ushr 8).toByte()
        head[10] = (crc and 0xFF).toByte()
        out.write(head)
        if (frame.payload.isNotEmpty()) out.write(frame.payload)
        out.flush()
    }

    /** 读一帧；返回 null 表示流正常结束 */
    @Throws(IOException::class)
    fun read(input: DataInputStream): Frame? {
        val head = ByteArray(HEADER_SIZE)
        readFullyOrEof(input, head) ?: return null

        if (head[0] != MAGIC_A.toByte() || head[1] != MAGIC_B.toByte()) {
            throw IOException("坏帧：MAGIC 不匹配")
        }
        if (head[2].toInt() != VERSION) {
            throw IOException("坏帧：协议版本不支持 v${head[2].toInt()}")
        }
        val type = head[3].toInt() and 0xFF
        val flags = head[4].toInt() and 0xFF
        val len = ((head[5].toInt() and 0xFF) shl 24) or
            ((head[6].toInt() and 0xFF) shl 16) or
            ((head[7].toInt() and 0xFF) shl 8) or
            (head[8].toInt() and 0xFF)
        if (len < 0 || len > 16 * 1024 * 1024) {
            throw IOException("坏帧：载荷长度异常 $len")
        }
        val crc = ((head[9].toInt() and 0xFF) shl 8) or (head[10].toInt() and 0xFF)

        val payload = if (len > 0) ByteArray(len).also { input.readFully(it) } else ByteArray(0)
        if (len > 0) {
            val c = CRC32().apply { update(payload) }
            if ((c.value and 0xFFFF).toInt() != crc) {
                throw IOException("坏帧：CRC 校验失败")
            }
        }
        return Frame(type, payload, needAck = (flags and FLAG_NEED_ACK) != 0)
    }

    private fun readFullyOrEof(input: DataInputStream, buf: ByteArray): ByteArray? {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n < 0) {
                if (off == 0) return null
                throw IOException("连接在帧中间断开")
            }
            off += n
        }
        return buf
    }

    fun hello(name: String) = Frame(FrameType.HELLO, name.toByteArray(Charsets.UTF_8))
    fun text(content: String) =
        Frame(FrameType.TEXT, content.toByteArray(Charsets.UTF_8), needAck = true)
    fun fileMeta(json: String) = Frame(FrameType.FILE_META, json.toByteArray(Charsets.UTF_8))

    /**
     * FILE_META：name 为 basename，size 为字节数；path 为批次内相对路径（正斜杠），
     * batch 为批次 id。旧端会忽略 path/batch 字段。
     */
    fun fileMeta(name: String, size: Long, path: String? = null, batch: String? = null): Frame {
        val json = JSONObject().put("name", name).put("size", size)
        if (path != null) json.put("path", path)
        if (batch != null) json.put("batch", batch)
        return Frame(FrameType.FILE_META, json.toString().toByteArray(Charsets.UTF_8))
    }

    /** CONFIG：手机端下发传输上限（字节），0 表示不限 */
    fun config(maxBytes: Long) =
        Frame(FrameType.CONFIG, "{\"maxBytes\":$maxBytes}".toByteArray(Charsets.UTF_8))

    fun batchMeta(json: String) = Frame(FrameType.BATCH_META, json.toByteArray(Charsets.UTF_8))
    fun batchEnd(json: String) = Frame(FrameType.BATCH_END, json.toByteArray(Charsets.UTF_8))
    fun chunk(data: ByteArray, from: Int, length: Int) =
        Frame(FrameType.FILE_CHUNK, data.copyOfRange(from, from + length))
    fun fileEnd() = Frame(FrameType.FILE_END, ByteArray(0), needAck = true)
    fun ack(ofType: Int) = Frame(FrameType.ACK, byteArrayOf(ofType.toByte()))
    fun pong() = Frame(FrameType.PONG, ByteArray(0))
    fun error(message: String) = Frame(FrameType.ERROR, message.toByteArray(Charsets.UTF_8))

    /** FILE_META → CHUNK* → FILE_END 的接收组装器 */
    class FileAssembler(var maxBytes: Long = MAX_FILE) {
        var name: String = "file"
            private set
        var expectedSize: Long = -1
            private set
        var received: Long = 0
            private set
        var overflow: Boolean = false
            private set

        private val buffer = ByteArrayOutputStream()

        fun onMeta(name: String, size: Long) {
            this.name = name
            this.expectedSize = size
            buffer.reset()
            received = 0
            overflow = false
        }

        fun onChunk(data: ByteArray) {
            if (overflow) return
            if (received + data.size > maxBytes) {
                overflow = true
                buffer.reset()
                return
            }
            buffer.write(data)
            received += data.size
        }

        fun bytes(): ByteArray = buffer.toByteArray()

        fun clear() {
            name = "file"
            expectedSize = -1
            received = 0
            overflow = false
            buffer.reset()
        }
    }
}
