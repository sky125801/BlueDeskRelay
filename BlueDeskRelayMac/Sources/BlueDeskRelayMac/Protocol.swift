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

    /// `writeSync` 单次写入不得超出 RFCOMM 通道 MTU；拿不到 MTU 时用这个保守值。
    static let fallbackMTU = 990

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
        /// 网络端点（手机 → PC）：{"port":47654,"ips":["192.168.1.23"],"name":"BlueDesk-A1B2C3"}
        static let netInfo: UInt8 = 0x0D
        /// 身份补充（PC → 手机）：{"id":"uuid","bt":"AA:BB:..","platform":"mac","transport":"tcp"}
        static let ident: UInt8 = 0x0E
        /// 代理能力宣告（PC → 手机）：{"script":1,"platform":"mac","unicode":1,"secure":0|1}
        static let agentInfo: UInt8 = 0x0F
        /// 脚本步骤（手机 → PC）：{"id","t","x","y","abs","w","k","txt"}
        static let scriptStep: UInt8 = 0x10
        /// 脚本步骤结果（PC → 手机）：{"id","ok","err"}
        static let scriptStepAck: UInt8 = 0x11
        /// 录制控制（手机 → PC）：{"on":true|false}
        static let recordCtrl: UInt8 = 0x12
        /// 录制结果（PC → 手机）：{"ok","recording","name","script","err"}
        static let recordResult: UInt8 = 0x13

        /// 实时键鼠输入（手机 → PC，独立输入车道）
        static let liveInput: UInt8 = 0x14

        /// 输入链路状态（PC → 手机，约 100ms 一次）
        static let inputState: UInt8 = 0x15

        /// 通知镜像（手机 → PC）：{"app","title","text","at","pkg"}
        static let notification: UInt8 = 0x16

        /// 剪贴板同步（双向）：{"text":"…","at":…}
        static let clipboard: UInt8 = 0x17

        /// 设备策略（手机 → PC）：{"lockOnDisconnect":true}
        /// 缓存在本地，控制链路断开时据此决定是否锁屏
        static let devicePolicy: UInt8 = 0x18
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

    /// 已是切片数据的便捷入口（发送端按块从磁盘流式读取时用）
    static func chunk(_ data: Data) -> Frame {
        Frame(type: FrameType.fileChunk, payload: data)
    }

    static func fileEnd(needAck: Bool = true) -> Frame {
        Frame(type: FrameType.fileEnd, payload: Data(), needAck: needAck)
    }

    static func ack(of type: UInt8) -> Frame {
        Frame(type: FrameType.ack, payload: Data([type]))
    }

    static func ping() -> Frame {
        Frame(type: FrameType.ping, payload: Data())
    }

    static func pong() -> Frame {
        Frame(type: FrameType.pong, payload: Data())
    }

    static func error(_ message: String) -> Frame {
        Frame(type: FrameType.error, payload: Data(message.utf8))
    }

    /// NET_INFO（手机下发的 TCP 数据通道端点）
    static func netInfo(_ json: String) -> Frame {
        Frame(type: FrameType.netInfo, payload: Data(json.utf8))
    }

    /// IDENT（PC 补报稳定标识，走 TCP 时用于把会话还原成同一台 PC）
    static func ident(_ json: String) -> Frame {
        Frame(type: FrameType.ident, payload: Data(json.utf8))
    }

    /// AGENT_INFO：告诉手机本机可代跑脚本步骤（CGEvent 本地注入）
    /// input/text 用于宣告实时输入车道与 Unicode 文本直送能力
    static func agentInfo(script: Bool, platform: String, unicode: Bool, secure: Bool,
                          input: Bool = false, text: Bool = false) -> Frame {
        let json = "{\"script\":\(script ? 1 : 0),\"platform\":\"\(jsonEscaped(platform))\"," +
            "\"unicode\":\(unicode ? 1 : 0),\"secure\":\(secure ? 1 : 0)," +
            "\"input\":\(input ? 1 : 0),\"text\":\(text ? 1 : 0)}"
        return Frame(type: FrameType.agentInfo, payload: Data(json.utf8))
    }

    /// INPUT_STATE：输入车道回执（已应用序号 + 注入是否成功）
    static func inputState(appliedSeq: Int64, ok: Bool) -> Frame {
        let json = "{\"appliedSeq\":\(appliedSeq),\"rtt\":0,\"ok\":\(ok ? 1 : 0)}"
        return Frame(type: FrameType.inputState, payload: Data(json.utf8))
    }

    /// CLIPBOARD：剪贴板同步（不落记录、不播提示音，两端各自抑制回环）
    static func clipboard(_ text: String) -> Frame {
        let json = "{\"text\":\"\(jsonEscaped(text))\"}"
        return Frame(type: FrameType.clipboard, payload: Data(json.utf8))
    }

    /// SCRIPT_STEP_ACK：单个脚本步骤的执行结果
    static func scriptStepAck(id: String, ok: Bool, err: String?) -> Frame {
        let errPart = err.map { "\"\(jsonEscaped($0))\"" } ?? "null"
        let json = "{\"id\":\"\(jsonEscaped(id))\",\"ok\":\(ok ? "true" : "false"),\"err\":\(errPart)}"
        return Frame(type: FrameType.scriptStepAck, payload: Data(json.utf8))
    }

    /// RECORD_RESULT：录制状态 / 结果；结束时 scriptJson 是整份脚本对象
    static func recordResult(ok: Bool, recording: Bool,
                             name: String? = nil, scriptJson: String? = nil,
                             err: String? = nil) -> Frame {
        var json = "{\"ok\":\(ok ? "true" : "false"),\"recording\":\(recording ? "true" : "false")"
        if let name { json += ",\"name\":\"\(jsonEscaped(name))\"" }
        if let err { json += ",\"err\":\"\(jsonEscaped(err))\"" }
        if let scriptJson { json += ",\"script\":\(scriptJson)" }
        json += "}"
        return Frame(type: FrameType.recordResult, payload: Data(json.utf8))
    }

    // MARK: - 解析（流式喂入，产出完整帧）

    /// 增量解析器：IOBluetooth 回调给的 data 可能是任意切割，先攒后切。
    ///
    /// 只记录已消费的偏移，最后一次性裁掉前缀 —— 旧实现每帧都 `removeSubrange`，
    /// 收几 MB 文件时是 O(n²) 的拷贝，会把跑回调的主线程拖住。
    struct Parser {
        private(set) var buffer = Data()
        private var parsingError: String?

        mutating func feed(_ data: Data) -> [Frame] {
            buffer.append(data)
            var frames: [Frame] = []
            let start = buffer.startIndex
            let available = buffer.count
            var consumed = 0

            while available - consumed >= headerSize {
                let base = start + consumed
                guard buffer[base] == 0xBD, buffer[base + 1] == 0x54 else {
                    parsingError = "坏帧：MAGIC 不匹配"
                    break
                }
                guard buffer[base + 2] == 0x01 else {
                    parsingError = "坏帧：协议版本不支持 v\(buffer[base + 2])"
                    break
                }
                let type = buffer[base + 3]
                let needAck = (buffer[base + 4] & flagNeedAck) != 0
                let len = Int(buffer[base + 5]) << 24 | Int(buffer[base + 6]) << 16
                    | Int(buffer[base + 7]) << 8 | Int(buffer[base + 8])
                guard len >= 0, len <= 16 * 1024 * 1024 else {
                    parsingError = "坏帧：载荷长度异常 \(len)"
                    break
                }
                let crc = Int(buffer[base + 9]) << 8 | Int(buffer[base + 10])
                guard available - consumed >= headerSize + len else { break }   // 等更多数据

                let payloadStart = base + headerSize
                let payload = buffer.subdata(in: payloadStart..<(payloadStart + len))

                if len > 0 {
                    let actual = Int(crc32(payload) & 0xFFFF)
                    if actual != crc {
                        parsingError = "坏帧：CRC 校验失败"
                        break
                    }
                }
                frames.append(Frame(type: type, payload: payload, needAck: needAck))
                consumed += headerSize + len
            }

            if let err = parsingError {
                NSLog("[Protocol] \(err)")
                parsingError = nil
                buffer.removeAll()
            } else if consumed > 0 {
                buffer.removeSubrange(start..<(start + consumed))
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
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
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
        buffer.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(max(0, min(size, 8 * 1024 * 1024)))
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
