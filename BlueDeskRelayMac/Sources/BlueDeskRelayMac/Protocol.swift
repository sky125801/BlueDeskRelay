import Foundation

/// BlueDesk 中转传输协议（与手机端 TransferProtocol.kt / Windows 端 Protocol.cs 逐字节对齐）
///
/// 帧格式（定长 11 字节头 + 载荷）：
///   0  2  MAGIC = 0xBD 0x54
///   2  1  VER = 1
///   3  1  TYPE（见 FrameType）
///   4  1  FLAGS（bit0 = 需要回 ACK）
///   5  4  PAYLOAD_LEN（u32 大端）
///   9  2  CRC32 低 16 位（大端；空载荷 0xFFFF）
///   11 n  payload
enum Protocol {

    static let headerSize = 11
    static let maxChunk = 4 * 1024

    /// 与手机端 TransferProtocol.SERVICE_UUID 一致
    static let serviceUUID = UUID(uuidString: "a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1")!

    enum FrameType {
        static let hello: UInt8 = 0x01
        static let text: UInt8 = 0x02
        static let fileMeta: UInt8 = 0x03
        static let fileChunk: UInt8 = 0x04
        static let fileEnd: UInt8 = 0x05
        static let ack: UInt8 = 0x06
        static let ping: UInt8 = 0x07
        static let pong: UInt8 = 0x08
        static let error: UInt8 = 0x09
        static let config: UInt8 = 0x0A
        static let batchMeta: UInt8 = 0x0B
        static let batchEnd: UInt8 = 0x0C
    }

    static let flagNeedAck: UInt8 = 0x01

    struct Frame {
        let type: UInt8
        let payload: Data
        var needAck: Bool = false
    }

    // MARK: - 编码

    static func encode(_ frame: Frame) -> Data {
        var data = Data(capacity: headerSize + frame.payload.count)
        var crc: UInt16 = 0xFFFF
        if !frame.payload.isEmpty {
            crc = UInt16(truncatingIfNeeded: crc32(frame.payload) & 0xFFFF)
        }
        data.append(0xBD)
        data.append(0x54)
        data.append(0x01)                       // version
        data.append(frame.type)
        data.append(frame.needAck ? flagNeedAck : 0)
        var len = UInt32(frame.payload.count).bigEndian
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        var crcBE = crc.bigEndian
        withUnsafeBytes(of: &crcBE) { data.append(contentsOf: $0) }
        data.append(frame.payload)
        return data
    }

    // MARK: - 常用载荷

    static func hello(_ machineName: String) -> Frame {
        Frame(type: FrameType.hello, payload: Data(machineName.utf8))
    }

    static func text(_ content: String, needAck: Bool = true) -> Frame {
        Frame(type: FrameType.text, payload: Data(content.utf8), needAck: needAck)
    }

    static func fileMeta(name: String, size: Int) -> Frame {
        let json = "{\"name\":\"\(jsonEscaped(name))\",\"size\":\(size)}"
        return Frame(type: FrameType.fileMeta, payload: Data(json.utf8))
    }

    static func chunk(_ data: Data, offset: Int, length: Int) -> Frame {
        Frame(type: FrameType.fileChunk, payload: data.subdata(in: offset..<offset + length))
    }

    static func fileEnd(needAck: Bool = true) -> Frame {
        Frame(type: FrameType.fileEnd, payload: Data(), needAck: needAck)
    }

    static func ack(of type: UInt8) -> Frame {
        Frame(type: FrameType.ack, payload: Data([type]))
    }

    static func pong() -> Frame {
        Frame(type: FrameType.pong, payload: Data())
    }

    static func error(_ message: String) -> Frame {
        Frame(type: FrameType.error, payload: Data(message.utf8))
    }

    // MARK: - 解析（流式喂入，产出完整帧）

    /// 增量解析器：IOBluetooth 回调给的 data 可能是任意切割，先攒后切
    struct Parser {
        private(set) var buffer = Data()
        private var parsingError: String?

        mutating func feed(_ data: Data) -> [Frame] {
            buffer.append(data)
            var frames: [Frame] = []
            while true {
                guard buffer.count >= headerSize else { break }
                let head = buffer.prefix(headerSize)
                guard head[0] == 0xBD, head[1] == 0x54 else {
                    parsingError = "坏帧：MAGIC 不匹配"
                    break
                }
                guard head[2] == 0x01 else {
                    parsingError = "坏帧：协议版本不支持 v\(head[2])"
                    break
                }
                let type = head[3]
                let needAck = (head[4] & flagNeedAck) != 0
                let len = Int(head[5]) << 24 | Int(head[6]) << 16 | Int(head[7]) << 8 | Int(head[8])
                guard len >= 0, len <= 16 * 1024 * 1024 else {
                    parsingError = "坏帧：载荷长度异常 \(len)"
                    break
                }
                let crc = Int(head[9]) << 8 | Int(head[10])
                guard buffer.count >= headerSize + len else { break }   // 等更多数据

                let payloadStart = buffer.index(buffer.startIndex, offsetBy: headerSize)
                let payloadEnd = buffer.index(payloadStart, offsetBy: len)
                let payload = buffer.subdata(in: payloadStart..<payloadEnd)

                if len > 0 {
                    let actual = Int(crc32(payload) & 0xFFFF)
                    if actual != crc {
                        parsingError = "坏帧：CRC 校验失败"
                        break
                    }
                }
                frames.append(Frame(type: type, payload: payload, needAck: needAck))
                buffer.removeSubrange(buffer.startIndex..<payloadEnd)
            }
            if let err = parsingError {
                NSLog("[Protocol] \(err)")
                parsingError = nil
                buffer.removeAll()
            }
            return frames
        }
    }

    // MARK: - 工具

    // MARK: - CRC32（查表法，与 java.util.zip.CRC32 / C# Crc32 一致）

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[n] = c
        }
        return table
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var result: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<data.count {
                result = crcTable[Int((result ^ UInt32(base[i])) & 0xFF)] ^ (result >> 8)
            }
        }
        return result ^ 0xFFFFFFFF
    }

    private static func jsonEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// 文件接收组装器（FILE_META → CHUNK* → FILE_END）
final class FileAssembler {
    private(set) var name = "file"
    private(set) var expectedSize: Int = -1
    private(set) var received = 0
    private var buffer = Data()

    func begin(name: String, size: Int) {
        self.name = name
        expectedSize = size
        buffer.removeAll()
        received = 0
    }

    func append(_ data: Data) {
        buffer.append(data)
        received += data.count
    }

    /// 落盘（同名自动加序号），返回完整路径
    func save(to dir: URL) throws -> String {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        var url = dir.appendingPathComponent(safe)
        var i = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base)(\(i))" : "\(base)(\(i)).\(ext)")
            i += 1
        }
        try buffer.write(to: url)
        return url.path
    }
}
