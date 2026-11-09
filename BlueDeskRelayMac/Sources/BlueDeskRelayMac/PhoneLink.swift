import Foundation
import IOBluetooth

/// 与手机的蓝牙 SPP（RFCOMM）数据通道 —— 经典蓝牙，须先在系统蓝牙设置里与手机配对。
///
/// 连接模型：
///   1. 在已配对设备里找名为 BlueDesk* 的手机；
///   2. SDP 查询自定义服务 UUID 对应的 RFCOMM 通道号并建立链路；
///   3. 先发 HELLO（本机名），随后收循环：
///      TEXT → 回调写剪贴板；FILE_META/CHUNK/END → 组装落盘 Downloads/BlueDesk；
///      needAck 的帧回 ACK；PING 回 PONG。
///
/// IOBluetooth 的回调走主 RunLoop，本类限定主线程使用（菜单栏程序天然满足）。
final class PhoneLink: NSObject, IOBluetoothRFCOMMChannelDelegate {

    private(set) var isConnected = false
    private(set) var phoneName = ""
    /// 当前连接设备的 MAC 地址（未连接为 nil；菜单打勾与记忆逻辑用）
    private(set) var connectedAddress: String?

    /// 收到文本（主线程回调）
    var onText: ((String) -> Void)?
    /// 收到文件（主线程回调，参数：落盘路径 / 大小）
    var onFile: ((String, Int) -> Void)?
    /// 连接状态变化（主线程回调）
    var onStateChange: ((Bool, String) -> Void)?
    /// 需要在气泡里展示的错误
    var onError: ((String) -> Void)?

    private var channel: IOBluetoothRFCOMMChannel?
    private var parser = Protocol.Parser()
    private var assembler: FileAssembler?
    private var phoneDevice: IOBluetoothDevice?
    /// 正在连接中的目标（连接是多步异步的：先 page 经典蓝牙 ACL，再开 RFCOMM）
    private var pendingDevice: IOBluetoothDevice?
    private var connectAttempt = 0

    var receiveDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dir = downloads.appendingPathComponent("BlueDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var localName: String {
        Host.current().localizedName ?? "Mac"
    }

    // MARK: - 连接管理

    /// 已配对设备列表（供手动选择菜单展示）：(名称, MAC 地址)
    /// 同一台手机可能出现多个配对实例（BR/EDR 与 LE 各一条），按地址去重，避免菜单里出现重复项。
    func pairedDeviceList() -> [(name: String, address: String)] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var seen = Set<String>()
        var result: [(name: String, address: String)] = []
        for device in devices {
            guard let address = device.addressString, !seen.contains(address) else { continue }
            seen.insert(address)
            result.append((device.name ?? address, address))
        }
        return result
    }

    /// 手动选择的目标设备地址（持久化；重启后自动优先连它）
    var preferredAddress: String? {
        get { UserDefaults.standard.string(forKey: "bluedesk.relay.preferredAddress") }
        set { UserDefaults.standard.set(newValue, forKey: "bluedesk.relay.preferredAddress") }
    }

    /// 手动清除记忆，恢复默认自动发现（BlueDesk* 第一台）
    func clearPreferred() {
        preferredAddress = nil
    }

    /// 自动连接：优先记忆设备 → BlueDesk* 命名 → 任何提供中转服务的配对设备
    func connect() {
        assert(Thread.isMainThread)
        guard !isConnected, channel == nil, pendingDevice == nil else { return }

        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []

        // 1) 记忆的设备（可能已取消配对 → 兜底自动发现）
        if let address = preferredAddress,
           let remembered = devices.first(where: { $0.addressString == address }) {
            NSLog("[PhoneLink] 连接记忆设备：\(remembered.name ?? address)")
            connect(to: remembered)
            return
        }

        // 2) 名字以 BlueDesk 开头的已配对手机
        if let phone = devices.first(where: { ($0.name ?? "").hasPrefix("BlueDesk") }) {
            connect(to: phone)
            return
        }

        // 3) 兜底：手机可能显示真实机型名（如 SM-S9380），按 SDP 中转服务扫描。
        //    SDP 查询会阻塞，放到后台线程避免卡主线程 UI。
        let skipAddr = lastAutoTriedAddress
        let candidates = devices.filter { $0.addressString != skipAddr }
        NSLog("[PhoneLink] 后台 SDP 扫描 \(candidates.count) 台设备…")
        DispatchQueue.global(qos: .utility).async {
            for device in candidates {
                guard let addr = device.addressString else { continue }
                let sdpUUID = IOBluetoothSDPUUID(
                    bytes: withUnsafeBytes(of: Protocol.serviceUUID.uuid) { Array($0) }, length: 16)
                guard let record = device.getServiceRecord(for: sdpUUID) else { continue }
                var channelID: BluetoothRFCOMMChannelID = 0
                guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { continue }

                NSLog("[PhoneLink] 自动发现「\(device.name ?? "?")」提供中转服务")
                DispatchQueue.main.async {
                    self.lastAutoTriedAddress = addr
                    self.connect(to: device)
                }
                return
            }
            NSLog("[PhoneLink] 未发现提供中转服务的已配对设备（确认手机端中转服务已开启）")
        }
    }

    /// 上次自动发现尝试过的地址（无服务设备不反复查 SDP）
    private var lastAutoTriedAddress: String?

    /// 查询设备的 RFCOMM 中转服务通道号；无服务返回 nil
    ///
    /// 先读 SDP 缓存（快），缓存 miss 时主动 `performSDPQuery` 刷新再查。
    /// macOS 的 SDP 缓存在手机端服务重启后会过期，不刷新会导致永远找不到服务。
    private func relayChannelID(of device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        let sdpUUID = IOBluetoothSDPUUID(
            bytes: withUnsafeBytes(of: Protocol.serviceUUID.uuid) { Array($0) }, length: 16)

        // 1) 缓存命中
        if let record = device.getServiceRecord(for: sdpUUID) {
            var channelID: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { return nil }
            return channelID
        }

        // 2) 缓存 miss → 强制刷新 SDP 再查（阻塞调用，但调用方已在后台线程或菜单手动入口）
        NSLog("[PhoneLink] SDP 缓存 miss，刷新 \(device.name ?? "?") 的服务记录…")
        _ = device.performSDPQuery(nil)

        // performSDPQuery 是异步的，等一下让结果落地
        Thread.sleep(forTimeInterval: 2)

        guard let record = device.getServiceRecord(for: sdpUUID) else { return nil }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { return nil }
        NSLog("[PhoneLink] SDP 刷新后找到中转服务 channel=\(channelID)")
        return channelID
    }

    /// 连接指定设备（主线程调用）——「连接设备」菜单的手动入口
    func connect(to device: IOBluetoothDevice) {
        assert(Thread.isMainThread)
        guard !isConnected, channel == nil, pendingDevice == nil else { return }
        pendingDevice = device
        connectAttempt = 0
        attemptOpenRelay()
    }

    /// 真正打开 RFCOMM；失败时先主动 page 一次经典蓝牙 ACL，等链路建立后重试。
    ///
    /// 关键点：同一台手机对 Mac 同时以 LE(GATT) 与 BR/EDR 两种身份存在。只有 LE 链路时
    /// `openRFCOMMChannelSync` 会立刻返回 kIOReturnError（0xe00002bc），且它自己不会去
    /// page 手机；必须先 `openConnection()` 把经典蓝牙 ACL 拉起来，链路建立后再开 RFCOMM。
    ///
    /// SDP 查询（含可能的 performSDPQuery 刷新）放到后台线程，避免 Thread.sleep 卡主线程。
    private func attemptOpenRelay() {
        guard let phone = pendingDevice, let address = phone.addressString else {
            pendingDevice = nil
            NSLog("[PhoneLink] 目标设备无有效地址")
            return
        }
        connectAttempt += 1

        let attempt = connectAttempt
        DispatchQueue.global(qos: .userInitiated).async {
            // SDP 查询（可能触发 performSDPQuery + Thread.sleep，在后台执行）
            guard let channelID = self.relayChannelID(of: phone) else {
                DispatchQueue.main.async {
                    self.pendingDevice = nil
                    NSLog("[PhoneLink] 「\(phone.name ?? address)」未注册中转服务（手机端中转页需先开启服务）")
                    self.onError?(L10n.t("error.noRelayService", phone.name ?? address))
                }
                return
            }

            // 开 RFCOMM（writeSync 本身线程安全）
            var newChannel: IOBluetoothRFCOMMChannel?
            let status = phone.openRFCOMMChannelSync(&newChannel, withChannelID: channelID, delegate: self)

            DispatchQueue.main.async {
                if status == kIOReturnSuccess, let opened = newChannel {
                    self.pendingDevice = nil
                    self.channel = opened
                    self.phoneDevice = phone
                    self.phoneName = phone.name ?? "BlueDesk"
                    self.connectedAddress = address
                    self.isConnected = true
                    self.parser = Protocol.Parser()
                    self.preferredAddress = address
                    self.onStateChange?(true, self.phoneName)
                    self.sendFrame(Protocol.hello(self.localName))
                    NSLog("[PhoneLink] 已连接 \(self.phoneName)（RFCOMM 通道 \(channelID)，第 \(attempt) 次尝试）")
                    return
                }

                NSLog("[PhoneLink] 第 \(attempt) 次打开 RFCOMM 失败：0x\(String(status, radix: 16))（isConnected=\(phone.isConnected())）")

                guard self.connectAttempt < 3 else {
                    self.pendingDevice = nil
                    self.onError?(L10n.t("error.connectFailed", phone.name ?? address))
                    return
                }

                // 主动把经典蓝牙 ACL 拉起来（只有 LE 链路时 RFCOMM 必然失败）
                if !phone.isConnected() {
                    let open = phone.openConnection()
                    NSLog("[PhoneLink] 主动建立经典蓝牙链路：0x\(String(open, radix: 16))")
                }
                let delay: TimeInterval = self.connectAttempt == 1 ? 2.5 : 5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.isConnected,
                          self.pendingDevice?.addressString == address else { return }
                    self.attemptOpenRelay()
                }
            }
        }
    }

    /// 按地址查找已配对设备（菜单点击后还原目标）
    func pairedDevice(at address: String) -> IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?
            .first { $0.addressString == address }
    }

    func disconnect() {
        pendingDevice = nil
        connectAttempt = 0
        guard isConnected else { return }
        isConnected = false
        connectedAddress = nil
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        phoneDevice = nil
        assembler = nil
        onStateChange?(false, phoneName)
    }

    /// 手动断开（不清除记忆设备）
    func disconnectManual() {
        disconnect()
    }

    /// 定时重连入口（状态未连接时尝试一次）
    func ensureConnected() {
        if pendingDevice != nil { return }   // 正在多步连接中，别打断
        if !isConnected { connect() }
    }

    // MARK: - 发送

    func sendText(_ content: String) {
        guard isConnected else {
            onError?(L10n.t("error.notConnected"))
            return
        }
        sendFrame(Protocol.text(content))
    }

    func sendFile(at url: URL) {
        guard isConnected else {
            onError?(L10n.t("error.notConnected"))
            return
        }
        guard let bytes = try? Data(contentsOf: url) else {
            onError?(L10n.t("error.readFileFailed"))
            return
        }
        let chunkSize = Protocol.maxChunk

        DispatchQueue.global(qos: .userInitiated).async {
            self.sendFrame(Protocol.fileMeta(name: url.lastPathComponent, size: bytes.count))

            var offset = 0
            while offset < bytes.count {
                let len = min(chunkSize, bytes.count - offset)
                self.sendFrame(Protocol.chunk(bytes, offset: offset, length: len))
                offset += len
            }

            self.sendFrame(Protocol.fileEnd())
        }
    }

    private func sendFrame(_ frame: Protocol.Frame) {
        let data = Protocol.encode(frame)
        guard data.count <= Int(UInt16.max) else {
            NSLog("[PhoneLink] 帧过大 \(data.count) 字节，已丢弃")
            return
        }
        guard let ch = channel else { return }
        let status = data.withUnsafeBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnError }
            return ch.writeSync(UnsafeMutableRawPointer(mutating: base),
                                length: UInt16(data.count))
        }
        if status != kIOReturnSuccess {
            NSLog("[PhoneLink] 写入失败：0x\(String(status, radix: 16))")
            DispatchQueue.main.async { self.disconnect() }
        }
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!,
                           length dataLength: Int) {
        let incoming = Data(bytes: dataPointer, count: dataLength)
        let frames = parser.feed(incoming)
        for frame in frames {
            handleFrame(frame)
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        NSLog("[PhoneLink] 通道关闭")
        if isConnected {
            disconnect()
        }
    }

    // MARK: - 帧处理

    private func handleFrame(_ frame: Protocol.Frame) {
        switch frame.type {
        case Protocol.FrameType.text:
            let text = String(decoding: frame.payload, as: UTF8.self)
            onText?(text)
            if frame.needAck { sendFrame(Protocol.ack(of: frame.type)) }

        case Protocol.FrameType.fileMeta:
            do {
                let obj = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] ?? [:]
                let name = obj["name"] as? String ?? "file"
                let size = obj["size"] as? Int ?? -1
                guard size >= 0, size <= 64 * 1024 * 1024 else {
                    onError?(L10n.t("error.sizeOutOfRange"))
                    sendFrame(Protocol.error("file size out of range"))
                    return
                }
                let asm = FileAssembler()
                asm.begin(name: name, size: size)
                assembler = asm
            } catch {
                onError?(L10n.t("error.metaParseFailed"))
            }

        case Protocol.FrameType.fileChunk:
            assembler?.append(frame.payload)

        case Protocol.FrameType.fileEnd:
            guard let asm = assembler else { return }
            assembler = nil
            do {
                let path = try asm.save(to: receiveDirectory)
                onFile?(path, asm.received)
                if frame.needAck { sendFrame(Protocol.ack(of: frame.type)) }
            } catch {
                onError?(L10n.t("error.saveFailed", error.localizedDescription))
            }

        case Protocol.FrameType.ping:
            sendFrame(Protocol.pong())

        // 手机下发的传输上限与文件夹批次：macOS 端暂不支持文件夹传输，
        // 明确忽略这三类帧，不能报错也不断开连接。FILE_META 仍只用 name/size。
        case Protocol.FrameType.config,
             Protocol.FrameType.batchMeta,
             Protocol.FrameType.batchEnd:
            break

        default:
            break
        }
    }
}
