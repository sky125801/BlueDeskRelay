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
    func pairedDeviceList() -> [(name: String, address: String)] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.compactMap { device in
            guard let address = device.addressString else { return nil }
            return (device.name ?? address, address)
        }
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
        guard !isConnected, channel == nil else { return }

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

        // 3) 兜底：手机可能显示真实机型名（如 SM-S9380），按 SDP 中转服务扫描
        //    为避免卡顿，每次自动连接只尝试一台（轮换）。
        let candidates = devices.filter { $0.addressString != lastAutoTriedAddress }
        for device in candidates {
            if let channelID = relayChannelID(of: device) {
                NSLog("[PhoneLink] 自动发现「\(device.name ?? "?")」提供中转服务")
                lastAutoTriedAddress = device.addressString
                connect(to: device)
                return
            }
        }
        NSLog("[PhoneLink] 未发现提供中转服务的已配对设备（确认手机端中转服务已开启）")
    }

    /// 上次自动发现尝试过的地址（无服务设备不反复查 SDP）
    private var lastAutoTriedAddress: String?

    /// 查询设备的 RFCOMM 中转服务通道号；无服务返回 nil
    private func relayChannelID(of device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        let sdpUUID = IOBluetoothSDPUUID(
            bytes: withUnsafeBytes(of: Protocol.serviceUUID.uuid) { Array($0) }, length: 16)
        guard let record = device.getServiceRecord(for: sdpUUID) else { return nil }
        var channelID: BluetoothRFCOMMChannelID = 0
        record.getRFCOMMChannelID(&channelID)
        return channelID
    }

    /// 连接指定设备（主线程调用）——「连接设备」菜单的手动入口
    func connect(to device: IOBluetoothDevice) {
        assert(Thread.isMainThread)
        guard !isConnected, channel == nil else { return }

        let phone = device
        guard let address = phone.addressString else {
            NSLog("[PhoneLink] 目标设备无有效地址")
            return
        }

        guard let channelID = relayChannelID(of: phone) else {
            NSLog("[PhoneLink] 「\(phone.name ?? address)」未注册中转服务（手机端中转页需先开启服务）")
            onError?("「\(phone.name ?? address)」未提供中转服务，请在手机上打开 BlueDesk → 中转 → 开启中转服务")
            return
        }

        var newChannel: IOBluetoothRFCOMMChannel?
        let status = phone.openRFCOMMChannelSync(&newChannel, withChannelID: channelID, delegate: self)
        guard status == kIOReturnSuccess, let opened = newChannel else {
            NSLog("[PhoneLink] 打开 RFCOMM 通道失败：0x\(String(status, radix: 16))")
            onError?("连接「\(phone.name ?? address)」失败（请确认手机端中转服务已开启）")
            return
        }

        channel = opened
        phoneDevice = phone
        phoneName = phone.name ?? "BlueDesk"
        connectedAddress = address
        isConnected = true
        parser = Protocol.Parser()
        preferredAddress = address          // 记住手动选择，重启/重连优先用它
        onStateChange?(true, phoneName)

        // 报身份
        sendFrame(Protocol.hello(localName))
        NSLog("[PhoneLink] 已连接 \(phoneName)（RFCOMM 通道 \(channelID)）")
    }

    /// 按地址查找已配对设备（菜单点击后还原目标）
    func pairedDevice(at address: String) -> IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?
            .first { $0.addressString == address }
    }

    func disconnect() {
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
        if !isConnected { connect() }
    }

    // MARK: - 发送

    func sendText(_ content: String) {
        guard isConnected else {
            onError?("手机未连接")
            return
        }
        sendFrame(Protocol.text(content))
    }

    func sendFile(at url: URL) {
        guard isConnected else {
            onError?("手机未连接")
            return
        }
        guard let bytes = try? Data(contentsOf: url) else {
            onError?("读取文件失败")
            return
        }
        sendFrame(Protocol.fileMeta(name: url.lastPathComponent, size: bytes.count))
        var offset = 0
        while offset < bytes.count {
            let len = min(Protocol.maxChunk, bytes.count - offset)
            sendFrame(Protocol.chunk(bytes, offset: offset, length: len))
            offset += len
        }
        sendFrame(Protocol.fileEnd())
    }

    private func sendFrame(_ frame: Protocol.Frame) {
        guard let channel else { return }
        let data = Protocol.encode(frame)
        guard data.count <= Int(UInt16.max) else {
            NSLog("[PhoneLink] 帧过大 \(data.count) 字节，已丢弃")
            return
        }
        let status = data.withUnsafeBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnError }
            return channel.writeSync(UnsafeMutableRawPointer(mutating: base),
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
                    onError?("文件大小超限或未知")
                    sendFrame(Protocol.error("file size out of range"))
                    return
                }
                let asm = FileAssembler()
                asm.begin(name: name, size: size)
                assembler = asm
            } catch {
                onError?("文件元信息解析失败")
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
                onError?("保存文件失败：\(error.localizedDescription)")
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
