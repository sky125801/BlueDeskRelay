import Foundation
import IOBluetooth

/// 命令行连接诊断：`open -a "BlueDesk Relay.app" --args --diag`（结果写 /tmp/bluedesk-diag.txt）
/// 逐步打印：已配对设备 → SDP 中转服务查询（含强制刷新）→ RFCOMM 通道打开 → HELLO 收发
///
/// 加 `--diag-reset` 会在最后额外做一次「断开 ACL 再重连」的破坏性尝试（会短暂断掉手机↔Mac 的 HID 链路）。
enum Diagnostics {

    private static let outFile = "/tmp/bluedesk-diag.txt"
    private static let resetRequested = CommandLine.arguments.contains("--diag-reset")
        || FileManager.default.fileExists(atPath: "/tmp/bluedesk-diag-reset")

    private static func out(_ line: String) {
        print(line)
        if let fh = FileHandle(forWritingAtPath: outFile) {
            _ = try? fh.seekToEnd()
            fh.write(Data((line + "\n").utf8))
            try? fh.close()
        }
    }

    // MARK: - 错误码可读化

    private static func hex(_ status: IOReturn) -> String {
        "0x" + String(UInt32(bitPattern: Int32(truncatingIfNeeded: status)), radix: 16)
    }

    private static func name(_ status: IOReturn) -> String {
        switch status {
        case kIOReturnSuccess: return "kIOReturnSuccess"
        case kIOReturnError: return "kIOReturnError(通用失败)"
        case kIOReturnNoMemory: return "kIOReturnNoMemory"
        case kIOReturnNoResources: return "kIOReturnNoResources"
        case kIOReturnNoDevice: return "kIOReturnNoDevice(设备不在/连不上)"
        case kIOReturnNotPrivileged: return "kIOReturnNotPrivileged"
        case kIOReturnBadArgument: return "kIOReturnBadArgument"
        case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess(被占用)"
        case kIOReturnUnsupported: return "kIOReturnUnsupported"
        case kIOReturnTimeout: return "kIOReturnTimeout"
        case kIOReturnNotOpen: return "kIOReturnNotOpen"
        default: return "未知错误"
        }
    }

    private static func err(_ status: IOReturn) -> String {
        "\(name(status)) \(hex(status))"
    }

    // MARK: - 入口

    static func run() {
        try? Data().write(to: URL(fileURLWithPath: outFile))
        out("=== BlueDesk 中转连接诊断 \(Date()) ===")
        out("破坏性重连测试：\(resetRequested ? "开启" : "关闭")")

        if let ctrl = IOBluetoothHostController.default() {
            out("[0] 本机蓝牙：\(ctrl.nameAsString() ?? "?")  \(ctrl.addressAsString() ?? "?")  电源 \(String(describing: ctrl.powerState))")
        }

        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice], !devices.isEmpty else {
            out("[1] 未读到任何已配对设备（检查系统蓝牙权限：系统设置 → 隐私与安全性 → 蓝牙）")
            return
        }

        out("[1] 已配对设备（原始顺序，含重复项）：")
        for (i, d) in devices.enumerated() {
            out("    #\(i) \(d.name ?? "?")  \(d.addressString ?? "?")  connected=\(d.isConnected())  paired=\(d.isPaired())  class=\(hex(IOReturn(d.classOfDevice)))")
        }

        // 按地址归组：同一台设备可能出现多个 IOBluetoothDevice 实例（重复配对残留）
        var groups: [String: [IOBluetoothDevice]] = [:]
        var order: [String] = []
        for d in devices {
            guard let addr = d.addressString else { continue }
            if groups[addr] == nil { order.append(addr) }
            groups[addr, default: []].append(d)
        }
        for addr in order where (groups[addr]?.count ?? 0) > 1 {
            out("[1] ⚠ 地址 \(addr) 有 \(groups[addr]!.count) 个配对实例（重复配对残留，建议删掉多余项）")
        }

        let sdpUUID = IOBluetoothSDPUUID(
            bytes: withUnsafeBytes(of: Protocol.serviceUUID.uuid) { Array($0) }, length: 16)

        // 逐设备：先读缓存 SDP，再强制刷新 SDP 对比
        var targets: [(device: IOBluetoothDevice, channel: BluetoothRFCOMMChannelID, name: String)] = []
        /// 对照组：同一台手机上别的 RFCOMM 服务（用来区分「RFCOMM 整体不通」与「BlueDesk 服务本身拒连」）
        var controls: [(device: IOBluetoothDevice, channel: BluetoothRFCOMMChannelID, name: String)] = []
        for addr in order {
            guard let instances = groups[addr] else { continue }
            let label = instances[0].name ?? addr
            out("")
            out("[2] ── \(label)  \(addr) ──")

            // 2.1 缓存 SDP
            for (i, d) in instances.enumerated() {
                if let record = d.getServiceRecord(for: sdpUUID) {
                    var ch: BluetoothRFCOMMChannelID = 0
                    let st = record.getRFCOMMChannelID(&ch)
                    out("    [2.1] 实例#\(i) 缓存 SDP：有中转服务  channel=\(ch)  name=\(record.getServiceName() ?? "?")  (\(err(st)))")
                    targets.append((d, ch, label))
                } else {
                    out("    [2.1] 实例#\(i) 缓存 SDP：无中转服务")
                }
            }

            // 2.2 强制刷新 SDP（排除「App 重启后通道号变了、缓存过期」）
            let refresh = instances[0].performSDPQuery(nil)
            out("    [2.2] performSDPQuery → \(err(refresh))，等待 3s…")
            Thread.sleep(forTimeInterval: 3)
            if let record = instances[0].getServiceRecord(for: sdpUUID) {
                var ch: BluetoothRFCOMMChannelID = 0
                _ = record.getRFCOMMChannelID(&ch)
                out("    [2.2] 刷新后中转服务：channel=\(ch)  name=\(record.getServiceName() ?? "?")")
            } else {
                out("    [2.2] 刷新后仍无中转服务记录")
            }

            // 2.3 枚举该设备全部 SDP 服务，看 RFCOMM 通道分布
            if let records = instances[0].services as? [IOBluetoothSDPServiceRecord] {
                out("    [2.3] 该设备共 \(records.count) 条 SDP 服务：")
                for r in records {
                    var ch: BluetoothRFCOMMChannelID = 0
                    let ok = r.getRFCOMMChannelID(&ch) == kIOReturnSuccess
                    out("          · \(r.getServiceName() ?? "(无名称)")\(ok ? "  rfcomm=\(ch)" : "  (非 RFCOMM)")")
                    if ok, let svcName = r.getServiceName(), svcName != "BlueDesk Relay" {
                        controls.append((instances[0], ch, svcName))
                    }
                }
            }
        }

        guard !targets.isEmpty else {
            out("")
            out("[3] ✗ 没有任何配对实例报告中转服务。请确认手机 BlueDesk「中转」页已开启服务后重试。")
            out("=== 诊断结束 ===")
            return
        }

        // 逐实例逐通道尝试打开（去重，避免重复试同一个）
        out("")
        out("[3] 尝试打开 RFCOMM（每个实例 × 通道，含 1s 重试）…")
        var opened: IOBluetoothRFCOMMChannel?
        var openedDesc = ""
        var seen = Set<String>()
        for t in targets {
            let key = "\(t.device.addressString ?? "?")#\(ObjectIdentifier(t.device))-\(t.channel)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            if !t.device.isConnected() {
                let st = t.device.openConnection()
                out("    「\(t.name)」ACL 未连接，openConnection → \(err(st))")
                Thread.sleep(forTimeInterval: 2)
            }

            for attempt in 1...2 {
                var ch: IOBluetoothRFCOMMChannel?
                let st = t.device.openRFCOMMChannelSync(&ch, withChannelID: t.channel, delegate: nil)
                if st == kIOReturnSuccess, let c = ch {
                    out("    ✓ 「\(t.name)」channel \(t.channel) 第 \(attempt) 次打开成功")
                    opened = c
                    openedDesc = "\(t.name) channel \(t.channel)"
                    break
                }
                out("    ✗ 「\(t.name)」channel \(t.channel) 第 \(attempt) 次失败：\(err(st))")
                if attempt == 1 { Thread.sleep(forTimeInterval: 1) }
            }
            if opened != nil { break }
        }

        if opened == nil {
            out("")
            out("[3.5] 对照组：尝试打开该手机上其它 RFCOMM 服务（判断 RFCOMM 整体是否可用）…")
            var controlOK = false
            for c in controls.prefix(2) {
                var ch: IOBluetoothRFCOMMChannel?
                let st = c.device.openRFCOMMChannelSync(&ch, withChannelID: c.channel, delegate: nil)
                out("    「\(c.name)」channel \(c.channel) → \(err(st))")
                if st == kIOReturnSuccess, let cc = ch {
                    controlOK = true
                    cc.close()
                    out("      （已关闭对照组通道）")
                    break
                }
            }
            if controls.isEmpty {
                out("    （没有可用的对照组通道）")
            }

            out("")
            out("[4] ✗ 所有实例都无法打开 RFCOMM。")
            if controlOK {
                out("    ⇒ 其它 RFCOMM 服务能打开，只有 BlueDesk 拒连：问题在手机 App 侧。")
                out("      · 手机 App 的 accept 循环已停（把「互传」开关关掉再打开）")
                out("      · 或上一次连接未释放，server socket 的 backlog 被占满")
            } else {
                out("    ⇒ 连其它 RFCOMM 服务也打不开：问题在链路/配对层，不在 BlueDesk。")
                out("      · 同一台手机有两个配对实例（重复配对残留，链路密钥可能不匹配）→ 删掉配对重配一次")
                out("      · 或手机侧蓝牙栈卡死 → 手机开关一次蓝牙")
            }
            out("    其它常见原因：")
            out("      · 手机 App 的中转服务已被系统回收（在手机上关掉再打开一次「互传」）")
            out("      · 手机侧上一次连接没释放（App 里手动断开 / 重启蓝牙）")

            if resetRequested, let first = targets.first?.device {
                out("")
                out("[4.1] 破坏性尝试：断开 ACL 后重连（最多等 15s）…")
                out("    closeConnection → \(err(first.closeConnection()))")
                Thread.sleep(forTimeInterval: 2)
                out("    openConnection → \(err(first.openConnection()))")
                var up = false
                for sec in 1...15 {
                    Thread.sleep(forTimeInterval: 1)
                    if first.isConnected() { up = true; out("    ✓ \(sec)s 后 ACL 建立"); break }
                }
                if !up { out("    ✗ 15s 内 ACL 未建立 —— 经典蓝牙（BR/EDR）链路连不上这台手机") }

                var ch: IOBluetoothRFCOMMChannel?
                let st = first.openRFCOMMChannelSync(&ch, withChannelID: targets[0].channel, delegate: nil)
                out("    RFCOMM 重试 → \(err(st))")
                if st == kIOReturnSuccess, let c = ch { opened = c }
            }
        }

        guard let channel = opened else {
            out("=== 诊断结束 ===")
            return
        }
        out("")
        out("[5] ✓ RFCOMM 通道已打开（\(openedDesc)），发送 HELLO…")

        let hello = Protocol.encode(Protocol.hello(Host.current().localizedName ?? "Mac-Diag"))
        let writeStatus = hello.withUnsafeBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnError }
            return channel.writeSync(UnsafeMutableRawPointer(mutating: base),
                                     length: UInt16(hello.count))
        }
        out("[6] \(writeStatus == kIOReturnSuccess ? "✓" : "✗") HELLO 写入：\(err(writeStatus))")
        out("    → 若以上全部 ✓：手机「互传」页应立即出现这台 Mac；若仍没有，看手机端 logcat -s TransferManager")

        sleep(2)
        channel.close()
        out("=== 诊断结束 ===")
    }
}
