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
/// 发送统一走一条专属写线程（见「发送队列」）：帧按 MTU 切片、缓冲满时退避重试、
/// 队列有上限做背压。任何线程都不直接 `writeSync`，避免阻塞主 RunLoop 或写坏字节流。
///
/// IOBluetooth 的回调走主 RunLoop，本类限定主线程使用（菜单栏程序天然满足）。
/// 例外是写线程与读盘线程，它们只通过 `sendLock` 保护的队列与本类交互。
final class PhoneLink: NSObject, IOBluetoothRFCOMMChannelDelegate {

    private(set) var isConnected = false
    private(set) var phoneName = ""
    /// 当前连接设备的 MAC 地址（未连接为 nil；菜单打勾与记忆逻辑用）
    private(set) var connectedAddress: String?

    /// 收到文本（主线程回调）
    var onText: ((String) -> Void)?
    /// 收到文件（主线程回调，参数：落盘路径 / 大小）
    var onFile: ((String, Int) -> Void)?
    /// 收到文件夹批次（主线程回调，参数：文件夹路径 / 文件数）
    var onFolder: ((String, Int) -> Void)?
    /// 文件已全部交给链路（主线程回调，参数：文件名 / 字节数）
    var onFileSent: ((String, Int) -> Void)?
    /// 连接状态变化（主线程回调）
    var onStateChange: ((Bool, String) -> Void)?
    /// 需要在气泡里展示的错误
    var onError: ((String) -> Void)?

    private var channel: IOBluetoothRFCOMMChannel?
    /// 整条会话走 TCP 的兜底通道（手填 Wi-Fi 或没有蓝牙时用；与 channel 互斥）
    private var tcp: TcpConnection?
    /// 蓝牙控制链路之外的 TCP 数据链路：只收发文件帧，控制帧仍走蓝牙
    private var dataLink: DataLink?
    private var dataLinkConnecting = false
    /// 数据链路下次允许重试的时间（失败后 5 秒重试，只在蓝牙控制链路在线时）
    private var dataLinkRetryAt = Date.distantPast
    /// 本轮蓝牙会话是否已收到 NET_INFO（避免控制会话尚未在手机端注册就抢先连数据链路）
    private var netInfoReceived = false
    private var parser = Protocol.Parser()
    private var assembler: FileAssembler?
    /// 当前批次（BATCH_META → 多文件 → BATCH_END）
    private var batch: BatchReceiver?
    private var pendingRelativePath: String?
    private var ignoreCurrentFile = false
    private var phoneDevice: IOBluetoothDevice?
    /// 正在连接中的目标（连接是多步异步的：先 page 经典蓝牙 ACL，再开 RFCOMM）
    private var pendingDevice: IOBluetoothDevice?
    private var connectAttempt = 0

    // MARK: - Wi-Fi 通道状态

    /// 蓝牙控制链路的分块大小（4 KB）；整条走 TCP 的兜底模式下为 64 KB
    private var chunkSize = Protocol.maxChunk
    /// 数据链路的分块大小（默认 64 KB，手机可通过 NET_INFO 覆盖）
    private var dataLinkChunkSize = 64 * 1024
    /// Wi-Fi 连续失败次数；达到阈值就忘掉端点，避免每轮重连都白等一次超时
    private var wifiFailures = 0
    /// Wi-Fi 探测冷却截止时间
    private var wifiCooldownUntil = Date.distantPast

    /// 手机下发的 Wi-Fi 端点（持久化，重启后直接可用，不必再走一次蓝牙握手）
    private var wifiHost: String? {
        get { UserDefaults.standard.string(forKey: "bluedesk.relay.wifiHost") }
        set { UserDefaults.standard.set(newValue, forKey: "bluedesk.relay.wifiHost") }
    }

    private var wifiPort: Int {
        get { UserDefaults.standard.integer(forKey: "bluedesk.relay.wifiPort") }
        set { UserDefaults.standard.set(newValue, forKey: "bluedesk.relay.wifiPort") }
    }

    /// 本机稳定标识：走 TCP 时手机拿不到 MAC，靠它把会话认回同一台 Mac
    private var localPeerId: String {
        if let existing = UserDefaults.standard.string(forKey: "bluedesk.relay.peerId") {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: "bluedesk.relay.peerId")
        return fresh
    }

    /// 当前是否走 Wi-Fi（界面显示用）：数据链路在线或整条兜底走 TCP
    var isWifi: Bool { dataLink != nil || tcp != nil }

    /// 当前通道描述（菜单显示用）
    var transportDescription: String {
        if dataLink != nil, let host = wifiHost {
            return "Wi-Fi \(host):\(wifiPort)"
        }
        if let tcp, tcp.isOpen, let host = wifiHost {
            return "Wi-Fi \(host):\(wifiPort)"
        }
        return "蓝牙"
    }

    // MARK: - 发送队列
    //
    // 所有写操作都由一条专属线程串行完成，理由有三：
    //   1. `writeSync` 要求单次写入不超过通道 MTU，一帧可能得拆成多次写；
    //      若别的线程插进来写 PONG/ACK，字节流就会错位。
    //   2. 对端缓冲满时 `writeSync` 会阻塞；旧实现在主线程写 PING 应答，
    //      一旦卡住就把派发 RFCOMM 回调的主 RunLoop 一起卡死，链路随即超时断开。
    //   3. 写失败要能重试，而不是把整条连接丢掉。

    private struct Outgoing {
        let frame: Protocol.Frame
        /// 该帧真正写入链路后的回调（主线程执行）
        let completion: (() -> Void)?
    }

    private let sendLock = NSCondition()
    private var sendQueue: [Outgoing] = []
    private var writerStop = true
    private var writerThread: Thread?
    /// 连接代号：每次建链/断链都自增。写线程与读盘循环各自绑定一个代号，
    /// 代号过期即收手 —— 否则断线重连后旧线程会把新连接的队列写坏。
    private var writerGeneration = 0
    /// 文件块待写队列上限（约 128 KB）；控制帧不受限，避免主线程被背压卡住
    private let maxPendingChunks = 32
    /// 单次 writeSync 的字节上限，连接建立后按通道 MTU 校正
    private var mtu = Protocol.fallbackMTU
    /// 手机端通过 CONFIG 下发的传输上限（0 = 不限）。收到前按 64 MB 处理。
    /// 不按它校验就硬发，手机会直接回 ERROR 并断开 —— 表现就是「传大文件必掉线」。
    private var phoneLimit = 64 * 1024 * 1024
    /// 单次写入持续失败多久才判定链路已死（期间会退避重试）
    private let writeTimeout: TimeInterval = 30
    /// 文件块之间的让出间隔（微秒）：给手机端读取循环喘息，别把缓冲灌满
    private let chunkPacing: UInt32 = 1_500

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

    /// 上次连上的手机名（走 Wi-Fi 时蓝牙那套设备名拿不到，用它显示）
    private var preferredName: String? {
        get { UserDefaults.standard.string(forKey: "bluedesk.relay.preferredName") }
        set { UserDefaults.standard.set(newValue, forKey: "bluedesk.relay.preferredName") }
    }

    /// 手动清除记忆，恢复默认自动发现（BlueDesk* 第一台）
    func clearPreferred() {
        preferredAddress = nil
    }

    /// 自动连接：蓝牙控制链路优先；没有已配对设备时才用手机下发的 Wi-Fi 端点整条兜底
    func connect() {
        assert(Thread.isMainThread)
        guard !isConnected, channel == nil, pendingDevice == nil, tcp == nil else { return }

        // 没有任何已配对设备时，退回手机上次下发的 Wi-Fi 端点
        if pairedDeviceList().isEmpty, wifiHost != nil, startWifiConnect() { return }

        connectBluetooth()
    }

    /// 蓝牙发现流程 —— Wi-Fi 不可用时的回落路径，逻辑与改造前完全一致
    private func connectBluetooth() {
        assert(Thread.isMainThread)
        guard !isConnected, channel == nil, pendingDevice == nil, tcp == nil else { return }

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
                    self.preferredName = self.phoneName
                    self.phoneLimit = 64 * 1024 * 1024   // 等手机端重新下发 CONFIG
                    self.chunkSize = Protocol.maxChunk   // 蓝牙仍按 4 KB 分块
                    self.dataLinkRetryAt = .distantPast
                    self.netInfoReceived = false          // 等本轮 NET_INFO 再连数据链路
                    self.mtu = Self.resolveMTU(of: opened)
                    self.startWriter(.rfcomm(opened))
                    self.onStateChange?(true, self.phoneName)
                    self.sendFrame(Protocol.hello(self.localName))
                    self.sendFrame(Protocol.ident(self.identJSON(wifi: false)))
                    NSLog("[PhoneLink] 已连接 \(self.phoneName)（RFCOMM 通道 \(channelID)，MTU \(self.mtu)，第 \(attempt) 次尝试）")
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

    func disconnect() { disconnect(silent: false) }

    /// `silent` = true 时不上报「已断开」：从蓝牙切到 Wi-Fi 用，
    /// 否则菜单栏会闪一条断开提示，其实只是换了条通道。
    private func disconnect(silent: Bool) {
        pendingDevice = nil
        connectAttempt = 0
        closeDataLink()
        guard isConnected else {
            tcp?.close()
            tcp = nil
            return
        }
        isConnected = false
        connectedAddress = nil
        // 先让写线程停手，再关通道：避免 close 与正在进行的 writeSync 抢同一个通道
        stopWriter()
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        phoneDevice = nil
        tcp?.close()
        tcp = nil
        assembler = nil
        batch = nil
        pendingRelativePath = nil
        ignoreCurrentFile = false
        netInfoReceived = false
        if !silent { onStateChange?(false, phoneName) }
    }

    /// 手动断开（不清除记忆设备）
    func disconnectManual() {
        disconnect()
    }

    // MARK: - Wi-Fi 通道

    /// 尝试走 Wi-Fi（TCP）。
    ///
    /// 返回 true 表示已经在连（异步进行），调用方不要再走蓝牙；
    /// 连不上会在回调里自动回落 `connectBluetooth()`。
    private func startWifiConnect() -> Bool {
        guard Date() >= wifiCooldownUntil,
              let host = wifiHost, wifiPort > 0 else { return false }
        let port = UInt16(truncatingIfNeeded: wifiPort)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let conn = TcpConnection()
            guard conn.connect(host: host, port: port, timeout: 4) else {
                conn.close()
                DispatchQueue.main.async {
                    self.wifiFailures += 1
                    self.wifiCooldownUntil = Date().addingTimeInterval(60)
                    NSLog("[PhoneLink] Wi-Fi \(host):\(port) 连不上（第 \(self.wifiFailures) 次），回落蓝牙")
                    if self.wifiFailures >= 3 {
                        self.wifiHost = nil
                        self.wifiPort = 0
                        self.wifiFailures = 0
                        NSLog("[PhoneLink] Wi-Fi 连续失败，已清除端点记忆")
                    }
                    self.connectBluetooth()
                }
                return
            }
            DispatchQueue.main.async { self.adoptWifi(conn, host: host, port: Int(port)) }
        }
        return true
    }

    /// Wi-Fi 通道建好后的收尾：登记状态 → 起写线程与读线程 → 报 HELLO / IDENT
    private func adoptWifi(_ conn: TcpConnection, host: String, port: Int) {
        guard !isConnected, channel == nil else {
            conn.close()
            return
        }
        closeDataLink()
        tcp = conn
        isConnected = true
        connectedAddress = nil
        if phoneName.isEmpty { phoneName = preferredName ?? "BlueDesk" }
        parser = Protocol.Parser()
        assembler = nil
        phoneLimit = 64 * 1024 * 1024      // 等手机重新下发 CONFIG
        chunkSize = dataLinkChunkSize      // 整条走 TCP，直接按 64 KB 分块
        wifiFailures = 0
        wifiCooldownUntil = .distantPast
        startWriter(.tcp(conn))
        startTcpReader(conn)
        onStateChange?(true, phoneName)
        sendFrame(Protocol.hello(localName))
        sendFrame(Protocol.ident(identJSON(wifi: true)))
        NSLog("[PhoneLink] 已连接 \(phoneName)（Wi-Fi \(host):\(port)，整条兜底模式）")
    }

    /// Wi-Fi 读线程：阻塞 recv → 喂同一个解析器 → 回主线程处理
    private func startTcpReader(_ conn: TcpConnection) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            while true {
                guard let data = conn.readSome(timeout: 1.0) else { break }
                if data.isEmpty { continue }
                let frames = self.parser.feed(data)
                if frames.isEmpty { continue }
                DispatchQueue.main.async {
                    for frame in frames { self.handleFrame(frame) }
                }
            }
            DispatchQueue.main.async {
                guard self.isConnected, self.tcp === conn else { return }
                NSLog("[PhoneLink] Wi-Fi 通道关闭")
                self.disconnect()
            }
        }
        thread.name = "BlueDeskRelay.tcpreader"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// 手机下发的网络端点：只保存端点并唤醒独立数据链路，不再切断蓝牙控制连接
    private func handleNetInfo(_ frame: Protocol.Frame) {
        guard let obj = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else {
            return
        }
        let port = obj["port"] as? Int ?? 0
        let ips = obj["ips"] as? [String] ?? []
        let chunk = obj["chunk"] as? Int ?? (64 * 1024)
        netInfoReceived = true

        if chunk > 0 {
            let size = min(max(chunk, Protocol.maxChunk), 256 * 1024)
            dataLinkChunkSize = size
            if tcp != nil { chunkSize = size }   // 整条走 TCP 的兜底模式
        }

        // 控制链路不是蓝牙时（整条 TCP 兜底）不需要数据链路
        guard channel != nil else { return }

        if port <= 0 || ips.isEmpty {
            wifiHost = nil
            wifiPort = 0
            let hadDataLink = dataLink != nil
            closeDataLink()
            if hadDataLink { onStateChange?(true, phoneName) }
            NSLog("[PhoneLink] 手机未提供 Wi-Fi 端点（可能没连 Wi-Fi），继续走蓝牙")
            return
        }

        let host = preferLanAddress(ips)
        if host != wifiHost || port != wifiPort {
            wifiCooldownUntil = .distantPast
            wifiFailures = 0
            dataLinkRetryAt = .distantPast
        }
        wifiHost = host
        wifiPort = port
        NSLog("[PhoneLink] 手机提供 Wi-Fi 端点 \(host):\(port)，尝试建立数据链路")
        ensureDataLink()
    }

    /// 多网卡时优先内网地址（192.168 / 10 / 172.16-31），其余按原顺序兜底
    private func preferLanAddress(_ ips: [String]) -> String {
        for ip in ips where ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return ip }
        for ip in ips where ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return ip }
        }
        return ips[0]
    }

    /// IDENT 载荷：优先让手机用蓝牙 MAC 当会话键，历史转发组才不会失配
    private func identJSON(wifi: Bool, role: String? = nil) -> String {
        let bt = IOBluetoothHostController.default()?.addressAsString() ?? ""
        var payload: [String: Any] = [
            "id": localPeerId,
            "bt": bt,
            "platform": "mac",
            "transport": wifi ? "tcp" : "bt",
        ]
        if let role { payload["role"] = role }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - TCP 数据链路（文件帧专用，控制帧仍走蓝牙）

    /// 连接数据链路；只有蓝牙控制链路在线时才尝试
    private func ensureDataLink() {
        assert(Thread.isMainThread)
        guard isConnected, channel != nil, tcp == nil, netInfoReceived else { return }
        guard dataLink == nil, !dataLinkConnecting else { return }
        guard Date() >= dataLinkRetryAt else { return }
        guard let host = wifiHost, wifiPort > 0 else { return }

        dataLinkConnecting = true
        let port = UInt16(truncatingIfNeeded: wifiPort)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let conn = TcpConnection()
            let ok = conn.connect(host: host, port: port, timeout: 4)
            DispatchQueue.main.async {
                guard let self else {
                    conn.close()
                    return
                }
                self.dataLinkConnecting = false
                guard ok else {
                    conn.close()
                    self.dataLinkRetryAt = Date().addingTimeInterval(5)
                    NSLog("[PhoneLink] 数据链路 \(host):\(port) 连不上，5 秒后重试")
                    return
                }
                guard self.isConnected, self.channel != nil,
                      self.netInfoReceived, self.dataLink == nil else {
                    conn.close()
                    return
                }
                self.adoptDataLink(DataLink(conn), host: host, port: Int(port))
            }
        }
    }

    /// 数据链路建好后报 HELLO + IDENT(role=data)，手机据此把它挂到蓝牙控制会话上
    private func adoptDataLink(_ link: DataLink, host: String, port: Int) {
        guard link.write(Protocol.hello(localName)),
              link.write(Protocol.ident(identJSON(wifi: true, role: "data"))) else {
            link.close()
            dataLinkRetryAt = Date().addingTimeInterval(5)
            return
        }
        dataLink = link
        dataLinkRetryAt = .distantPast
        startDataLinkReader(link)
        NSLog("[PhoneLink] 数据链路已建立（\(host):\(port)）")
        onStateChange?(true, phoneName)   // 刷新菜单里的通道描述
    }

    private func startDataLinkReader(_ link: DataLink) {
        let thread = Thread { [weak self, link] in
            while true {
                guard let data = link.conn.readSome(timeout: 1.0) else { break }
                if data.isEmpty { continue }
                let frames = link.parser.feed(data)
                if frames.isEmpty { continue }
                DispatchQueue.main.async {
                    guard let self, self.dataLink === link else { return }
                    for frame in frames { self.handleFrame(frame, from: .dataLink(link)) }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.dataLink === link else { return }
                self.dropDataLink(link)
            }
        }
        thread.name = "BlueDeskRelay.datalink"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// 数据链路断开：控制链路不受影响，5 秒后自动重连
    private func dropDataLink(_ link: DataLink) {
        guard dataLink === link else { return }
        dataLink = nil
        link.close()
        dataLinkRetryAt = Date().addingTimeInterval(5)
        NSLog("[PhoneLink] 数据链路断开，5 秒后重试")
        if isConnected { onStateChange?(true, phoneName) }
    }

    private func closeDataLink() {
        guard let link = dataLink else {
            dataLinkRetryAt = .distantPast
            return
        }
        dataLink = nil
        link.close()
        dataLinkRetryAt = .distantPast
    }

    /// 定时重连入口（状态未连接时尝试一次；数据链路另行重试）
    func ensureConnected() {
        if pendingDevice != nil { return }   // 正在多步连接中，别打断
        if !isConnected { connect() }
        ensureDataLink()
    }

    // MARK: - 发送

    func sendText(_ content: String) {
        guard isConnected else {
            onError?(L10n.t("error.notConnected"))
            return
        }
        sendFrame(Protocol.text(content))
    }

    /// 发送文件：按块从磁盘流式读取后入队，写线程负责流控与重试。
    ///
    /// 旧实现把整份文件读进内存、在后台线程里死循环 `writeSync`，任何一次写失败
    /// 都直接 `disconnect()` —— 几 MB 的文件几乎必然在中途掉线。现在：
    ///   - 读盘与入队分离，队列有上限（背压），内存占用恒定；
    ///   - 写失败退避重试，只有链路真的断了才报错；
    ///   - 帧按 MTU 切片写入，不会再因单次写入超长被拒。
    func sendFile(at url: URL) {
        // 数据链路正在建立时给 TCP 3 秒优先窗口：不区分文件大小，
        // 等不到才回落蓝牙，避免刚连上时的文件都落到蓝牙。
        sendFile(at: url, linkDeadline: Date().addingTimeInterval(3))
    }

    private func sendFile(at url: URL, linkDeadline: Date) {
        guard isConnected else {
            onError?(L10n.t("error.notConnected"))
            return
        }
        if dataLink == nil, dataLinkConnecting,
           wifiHost != nil, wifiPort > 0, Date() < linkDeadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.sendFile(at: url, linkDeadline: linkDeadline)
            }
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? -1
        guard size >= 0 else {
            onError?(L10n.t("error.readFileFailed"))
            return
        }
        // 先按手机端下发的上限拦一道：超限硬发只会换来 ERROR + 断链
        if phoneLimit > 0 && size > phoneLimit {
            onError?(L10n.t("error.exceedsPhoneLimit", ByteSize.human(phoneLimit)))
            return
        }

        // 绑定当前这条连接：中途断线重连后，旧文件的剩余块绝不能续写到新连接上
        // （FILE_META 只发过一次，续写会让手机端组装器错位）
        let generation = currentGeneration
        // 数据链路在线就走 TCP，否则走蓝牙控制链路；TEXT 始终走蓝牙
        let link = dataLink.flatMap { $0.isOpen ? $0 : nil }
        let chunk = link != nil ? dataLinkChunkSize : chunkSize
        let name = url.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                DispatchQueue.main.async { self.onError?(L10n.t("error.readFileFailed")) }
                return
            }
            defer { try? handle.close() }

            guard self.writeBulk(Protocol.fileMeta(name: name, size: size),
                                 to: link, generation: generation) else {
                self.reportBulkFailure(link)
                return
            }

            var sent = 0
            while sent < size {
                guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
                // 蓝牙走背压队列；数据链路直接阻塞写，由 TCP 自己流控
                guard self.writeBulk(Protocol.chunk(data), to: link,
                                     generation: generation, pacing: true) else {
                    self.reportBulkFailure(link)
                    return
                }
                sent += data.count
            }

            if let link {
                guard link.write(Protocol.fileEnd()) else {
                    self.reportBulkFailure(link)
                    return
                }
                DispatchQueue.main.async { self.onFileSent?(name, sent) }
            } else {
                self.enqueue(Protocol.fileEnd(), generation: generation) { [weak self] in
                    self?.onFileSent?(name, sent)
                }
            }
        }
    }

    /// 按目标链路写一帧：数据链路直写，蓝牙走发送队列（含背压）
    private func writeBulk(_ frame: Protocol.Frame, to link: DataLink?,
                           generation: Int, pacing: Bool = false) -> Bool {
        if let link { return link.write(frame) }
        return enqueue(frame, generation: generation, pacing: pacing)
    }

    private func reportBulkFailure(_ link: DataLink?) {
        guard let link else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dropDataLink(link)
            self.onError?(L10n.t("error.sendInterrupted"))
        }
    }

    private func sendFrame(_ frame: Protocol.Frame) {
        enqueue(frame, generation: currentGeneration)
    }

    /// 当前连接代号（调用方须在主线程或自行加锁，见 sendLock）
    private var currentGeneration: Int {
        sendLock.lock()
        defer { sendLock.unlock() }
        return writerGeneration
    }

    /// 入队一帧。返回 false 表示这条连接已不可写，调用方应放弃后续数据。
    @discardableResult
    private func enqueue(_ frame: Protocol.Frame,
                         generation: Int,
                         pacing: Bool = false,
                         completion: (() -> Void)? = nil) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard !writerStop, generation == writerGeneration else { return false }

        if pacing {
            // 队列满时等写线程消化（最多等 2 秒，超时就直接入队，宁可多占点内存也不卡死调用方）
            let deadline = Date().addingTimeInterval(2)
            while sendQueue.count >= maxPendingChunks && !writerStop
                    && generation == writerGeneration && Date() < deadline {
                _ = sendLock.wait(until: Date().addingTimeInterval(0.2))
            }
            guard !writerStop, generation == writerGeneration else { return false }
        }

        sendQueue.append(Outgoing(frame: frame, completion: completion))
        // 用 broadcast 而非 signal：可能还有上一代写线程在同一个条件变量上等待，
        // 若把它唤醒，它只会退出，真正该干活的新线程反而继续睡。
        sendLock.broadcast()
        return true
    }

    // MARK: - 写线程

    /// 写线程的输出去向：蓝牙通道或 Wi-Fi TCP 连接
    private enum Output {
        case rfcomm(IOBluetoothRFCOMMChannel)
        case tcp(TcpConnection)

        var isWifi: Bool {
            if case .tcp = self { return true }
            return false
        }
    }

    private func startWriter(_ output: Output) {
        sendLock.lock()
        sendQueue.removeAll()
        writerStop = false
        writerGeneration += 1
        let generation = writerGeneration
        let thread = Thread { [weak self] in self?.runWriter(output: output, generation: generation) }
        thread.name = "BlueDeskRelay.writer"
        thread.stackSize = 256 * 1024
        writerThread = thread
        sendLock.broadcast()   // 叫醒可能还挂在条件变量上的上一代写线程，让它自行退出
        sendLock.unlock()
        thread.start()
    }

    private func stopWriter() {
        sendLock.lock()
        writerStop = true
        writerGeneration += 1     // 让仍在跑（可能卡在 writeSync）的旧写线程彻底失效
        sendQueue.removeAll()
        writerThread = nil
        sendLock.broadcast()
        sendLock.unlock()
    }

    /// 该代号的写线程是否应当收手（断开、重连、或已被新一代取代）
    private func shouldStop(_ generation: Int) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        return writerStop || generation != writerGeneration
    }

    private func runWriter(output: Output, generation: Int) {
        while true {
            sendLock.lock()
            while sendQueue.isEmpty && !writerStop && generation == writerGeneration {
                sendLock.wait()
            }
            guard !writerStop, generation == writerGeneration else { sendLock.unlock(); return }
            let item = sendQueue.removeFirst()
            sendLock.unlock()

            guard writeFrame(item.frame, output: output, generation: generation) else {
                // 只有「当前这条连接」的写线程才允许把队列判死，旧线程不得干扰新连接
                sendLock.lock()
                let current = (generation == writerGeneration)
                if current {
                    writerStop = true
                    sendQueue.removeAll()
                }
                sendLock.unlock()
                guard current else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isConnected else { return }
                    NSLog("[PhoneLink] 写入持续失败，判定链路中断")
                    self.onError?(L10n.t("error.sendInterrupted"))
                    self.disconnect()
                }
                return
            }

            if let completion = item.completion {
                DispatchQueue.main.async(execute: completion)
            }
            // 文件块之间让出一点时间，避免把手机端接收缓冲一次灌满。
            // Wi-Fi 通道有 TCP 自己的流控，不需要这个间隔。
            if !output.isWifi && item.frame.type == Protocol.FrameType.fileChunk {
                usleep(chunkPacing)
            }
        }
    }

    /// 按通道类型分派：Wi-Fi 直接整帧写，蓝牙要走 MTU 切片
    private func writeFrame(_ frame: Protocol.Frame, output: Output, generation: Int) -> Bool {
        switch output {
        case .tcp(let conn):
            if shouldStop(generation) { return false }
            return conn.write(Protocol.encode(frame))
        case .rfcomm(let channel):
            return writeRFCOMMFrame(frame, on: channel, generation: generation)
        }
    }

    /// 按 MTU 切片写完整帧。返回 false 表示链路已不可用。
    private func writeRFCOMMFrame(_ frame: Protocol.Frame,
                                  on channel: IOBluetoothRFCOMMChannel,
                                  generation: Int) -> Bool {
        let data = Protocol.encode(frame)
        guard data.count <= Int(UInt16.max) else {
            NSLog("[PhoneLink] 帧过大 \(data.count) 字节，已丢弃")
            return true
        }

        var offset = 0
        while offset < data.count {
            if shouldStop(generation) { return false }
            let len = min(mtu, data.count - offset)
            let piece = data.subdata(in: offset..<(offset + len))
            switch writePiece(piece, on: channel, generation: generation) {
            case .ok:
                offset += len
            case .smaller:
                // MTU 估计偏大（部分机型协商出的值偏乐观）：减半重试
                guard mtu > 64 else { return false }
                mtu = max(64, mtu / 2)
                NSLog("[PhoneLink] 单次写入被拒，MTU 降到 \(mtu)")
            case .fatal:
                return false
            }
        }
        return true
    }

    private enum WriteOutcome { case ok, smaller, fatal }

    /// 单次 writeSync（长度已保证不超过 MTU）+ 退避重试。
    ///
    /// 关键：缓冲满 / 暂时不可写（NoResources、Busy、Timeout…）属于正常背压，
    /// 等一会儿再写即可；只有通道关闭、设备消失才算真断线。
    private func writePiece(_ piece: Data,
                            on channel: IOBluetoothRFCOMMChannel,
                            generation: Int) -> WriteOutcome {
        let deadline = Date().addingTimeInterval(writeTimeout)
        var backoff: UInt32 = 2_000
        var attempts = 0

        while true {
            if shouldStop(generation) { return .fatal }
            guard channel.isOpen() else { return .fatal }

            // 对端 RFCOMM 流控（手机接收缓冲满）：先等它放开，别硬灌
            var pausedFor = 0
            while channel.isTransmissionPaused() && !shouldStop(generation) {
                usleep(20_000)
                pausedFor += 20_000
                if pausedFor > 20_000_000 { return .fatal }
            }

            let status = piece.withUnsafeBytes { raw -> IOReturn in
                guard let base = raw.baseAddress else { return kIOReturnBadArgument }
                return channel.writeSync(UnsafeMutableRawPointer(mutating: base),
                                         length: UInt16(piece.count))
            }
            if status == kIOReturnSuccess { return .ok }

            attempts += 1
            NSLog("[PhoneLink] 写入失败 0x\(String(UInt32(bitPattern: Int32(truncatingIfNeeded: status)), radix: 16))"
                  + "（第 \(attempts) 次，长度 \(piece.count)，MTU \(mtu)）")

            switch status {
            case kIOReturnNotOpen, kIOReturnNoDevice, kIOReturnOffline, kIOReturnNotAttached:
                return .fatal
            case kIOReturnBadArgument:
                return .smaller
            default:
                break
            }

            if Date() >= deadline { return .fatal }
            usleep(backoff)
            backoff = min(backoff * 2, 100_000)
        }
    }

    /// 通道 MTU（单次写入上限）；异常值回退到保守默认
    private static func resolveMTU(of channel: IOBluetoothRFCOMMChannel) -> Int {
        let raw = Int(channel.getMTU())
        guard raw > 0 else { return Protocol.fallbackMTU }
        return min(max(raw, 64), 16 * 1024)
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

    /// 帧来源：控制链路（蓝牙/整条 TCP）或独立数据链路；ACK/PONG 必须原路返回
    private enum FrameSource {
        case control
        case dataLink(DataLink)
    }

    private func reply(_ frame: Protocol.Frame, to source: FrameSource) {
        switch source {
        case .control:
            sendFrame(frame)
        case .dataLink(let link):
            // ACK/PONG 很小，但 TCP 缓冲满时写仍可能阻塞；别占着主线程
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                if !link.write(frame) {
                    DispatchQueue.main.async { self.dropDataLink(link) }
                }
            }
        }
    }

    private func handleFrame(_ frame: Protocol.Frame, from source: FrameSource = .control) {
        switch frame.type {
        case Protocol.FrameType.text:
            let text = String(decoding: frame.payload, as: UTF8.self)
            onText?(text)
            if frame.needAck { reply(Protocol.ack(of: frame.type), to: source) }

        case Protocol.FrameType.batchMeta:
            handleBatchMeta(frame, from: source)

        case Protocol.FrameType.fileMeta:
            handleFileMeta(frame, from: source)

        case Protocol.FrameType.fileChunk:
            if !ignoreCurrentFile { assembler?.append(frame.payload) }

        case Protocol.FrameType.fileEnd:
            handleFileEnd(frame, from: source)

        case Protocol.FrameType.batchEnd:
            handleBatchEnd(frame, from: source)

        case Protocol.FrameType.ping:
            reply(Protocol.pong(), to: source)

        // 手机下发的 Wi-Fi 端点：只建立数据链路，控制链路继续走蓝牙
        case Protocol.FrameType.netInfo:
            handleNetInfo(frame)

        // 手机端下发的传输上限：记下来，发送前先自查，别等它拒收
        case Protocol.FrameType.config:
            guard let obj = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                  let max = obj["maxBytes"] as? Int else { return }
            phoneLimit = max > 0 ? max : 0
            NSLog("[PhoneLink] 手机端传输上限：\(phoneLimit > 0 ? "\(phoneLimit) B" : "不限")")

        case Protocol.FrameType.error:
            let message = String(decoding: frame.payload, as: UTF8.self)
            NSLog("[PhoneLink] 手机端返回错误：\(message)")
            onError?(L10n.t("error.phoneRejected", message))

        default:
            break
        }
    }

    private func handleFileMeta(_ frame: Protocol.Frame, from source: FrameSource) {
        do {
            let obj = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] ?? [:]
            let name = obj["name"] as? String ?? "file"
            let size = obj["size"] as? Int ?? -1
            pendingRelativePath = nil
            ignoreCurrentFile = false

            // 批次内文件：允许 size 未知，路径相对批次根目录
            if let batch, let batchId = obj["batch"] as? String, batchId == batch.id {
                if batch.discarding {
                    ignoreCurrentFile = true
                    return
                }
                if size > 64 * 1024 * 1024 {
                    batch.discarding = true
                    ignoreCurrentFile = true
                    onError?(L10n.t("error.sizeOutOfRange"))
                    reply(Protocol.error("file size out of range"), to: source)
                    return
                }
                pendingRelativePath = sanitizeRelativePath(obj["path"] as? String ?? name)
                    ?? sanitizeSegment(name)
                let asm = FileAssembler()
                asm.begin(name: name, size: size)
                assembler = asm
                return
            }

            guard size >= 0, size <= 64 * 1024 * 1024 else {
                onError?(L10n.t("error.sizeOutOfRange"))
                reply(Protocol.error("file size out of range"), to: source)
                return
            }
            let asm = FileAssembler()
            asm.begin(name: name, size: size)
            assembler = asm
        } catch {
            onError?(L10n.t("error.metaParseFailed"))
        }
    }

    private func handleFileEnd(_ frame: Protocol.Frame, from source: FrameSource) {
        if ignoreCurrentFile {
            ignoreCurrentFile = false
            pendingRelativePath = nil
            assembler = nil
            if frame.needAck { reply(Protocol.ack(of: frame.type), to: source) }
            return
        }

        // 批次内文件：落盘到 Downloads/BlueDesk/<文件夹>/<相对路径>
        if let batch, let rel = pendingRelativePath, let asm = assembler {
            assembler = nil
            pendingRelativePath = nil
            do {
                let dir = batch.root.appendingPathComponent(rel).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                _ = try asm.save(to: dir)
                batch.receivedFiles += 1
                batch.receivedBytes += asm.received
            } catch {
                batch.discarding = true
                onError?(L10n.t("error.saveFailed", error.localizedDescription))
                reply(Protocol.error("save file failed"), to: source)
            }
            if frame.needAck { reply(Protocol.ack(of: frame.type), to: source) }
            return
        }

        guard let asm = assembler else {
            if frame.needAck { reply(Protocol.ack(of: frame.type), to: source) }
            return
        }
        assembler = nil
        do {
            let path = try asm.save(to: receiveDirectory)
            onFile?(path, asm.received)
            if frame.needAck { reply(Protocol.ack(of: frame.type), to: source) }
        } catch {
            onError?(L10n.t("error.saveFailed", error.localizedDescription))
        }
    }

    private func handleBatchMeta(_ frame: Protocol.Frame, from source: FrameSource) {
        guard let obj = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else {
            NSLog("[PhoneLink] BATCH_META 缺少 id，已忽略")
            return
        }
        let declared = obj["bytes"] as? Int ?? 0
        let folder = uniqueFolderName(sanitizeSegment(obj["name"] as? String ?? "folder"))
        let root = receiveDirectory.appendingPathComponent(folder, isDirectory: true)
        let dirs = (obj["dirs"] as? [String] ?? []).compactMap { sanitizeRelativePath($0) }
        let receiver = BatchReceiver(id: id, folder: folder, root: root, dirs: dirs)
        batch = receiver
        pendingRelativePath = nil
        ignoreCurrentFile = false
        if frame.needAck { reply(Protocol.ack(of: frame.type), to: source) }
        NSLog("[PhoneLink] 开始接收文件夹「\(folder)」：\(obj["files"] as? Int ?? 0) 个文件 / \(declared) B")
    }

    private func handleBatchEnd(_ frame: Protocol.Frame, from source: FrameSource) {
        let current = batch
        batch = nil
        pendingRelativePath = nil
        ignoreCurrentFile = false
        defer {
            if frame.needAck { reply(Protocol.ack(of: frame.type), to: source) }
        }
        guard let current else { return }

        let obj = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
        let endId = (obj?["id"] as? String) ?? ""
        if !endId.isEmpty, endId != current.id {
            NSLog("[PhoneLink] BATCH_END id 不匹配（\(endId) ≠ \(current.id)），已忽略")
            return
        }
        guard !current.discarding else { return }

        // 补齐空目录，保证文件夹结构完整
        for dir in current.dirs {
            try? FileManager.default.createDirectory(
                at: current.root.appendingPathComponent(dir, isDirectory: true),
                withIntermediateDirectories: true)
        }
        NSLog("[PhoneLink] 文件夹「\(current.folder)」接收完成："
              + "\(current.receivedFiles) 个文件 / \(current.receivedBytes) B")
        onFolder?(current.root.path, current.receivedFiles)
    }

    // MARK: - 路径工具

    private func sanitizeSegment(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "folder" : cleaned
    }

    /// 只保留安全的相对路径段，杜绝 ../ 越界
    private func sanitizeRelativePath(_ raw: String) -> String? {
        let parts = raw.split(separator: "/").map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    private func uniqueFolderName(_ base: String) -> String {
        let dir = receiveDirectory
        var candidate = base
        var index = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(base)(\(index))"
            index += 1
        }
        return candidate
    }
}

/// 一条独立的 TCP 数据链路：只用于批量文件帧，控制帧仍走蓝牙。
/// 写入加锁，保证多线程（文件读盘线程 / 主线程回 ACK）不会把字节流写乱。
private final class DataLink {
    let conn: TcpConnection
    var parser = Protocol.Parser()
    private let writeLock = NSLock()

    init(_ conn: TcpConnection) {
        self.conn = conn
    }

    var isOpen: Bool { conn.isOpen }

    func write(_ frame: Protocol.Frame) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard conn.isOpen else { return false }
        return conn.write(Protocol.encode(frame))
    }

    func close() {
        conn.close()
    }
}

/// 文件夹批次接收上下文（BATCH_META → 多组 FILE_* → BATCH_END）
private final class BatchReceiver {
    let id: String
    let folder: String
    let root: URL
    let dirs: [String]
    var discarding = false
    var receivedFiles = 0
    var receivedBytes = 0

    init(id: String, folder: String, root: URL, dirs: [String]) {
        self.id = id
        self.folder = folder
        self.root = root
        self.dirs = dirs
    }
}
