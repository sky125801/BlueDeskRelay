import Foundation
import IOBluetooth

/// 命令行连接诊断：`open -a "BlueDesk Relay.app" --args --diag`（结果写 /tmp/bluedesk-diag.txt）
/// 逐步打印：已配对设备 → SDP 中转服务查询 → RFCOMM 通道打开 → HELLO 收发
enum Diagnostics {

    private static let outFile = "/tmp/bluedesk-diag.txt"

    private static func out(_ line: String) {
        print(line)
        if let fh = FileHandle(forWritingAtPath: outFile) {
            _ = try? fh.seekToEnd()
            fh.write(Data((line + "\n").utf8))
            try? fh.close()
        }
    }

    static func run() {
        try? Data().write(to: URL(fileURLWithPath: outFile))
        out("=== BlueDesk 中转连接诊断 \(Date()) ===")

        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice], !devices.isEmpty else {
            out("[1] 未读到任何已配对设备（检查系统蓝牙权限：系统设置 → 隐私与安全性 → 蓝牙）")
            return
        }
        out("[1] 已配对设备：")
        devices.forEach { out("    - \($0.name ?? "?")  \($0.addressString ?? "?")") }

        // 对每台配对设备查中转服务（不过滤名称 —— 手机可能显示真实机型名）
        let sdpUUID = IOBluetoothSDPUUID(
            bytes: withUnsafeBytes(of: Protocol.serviceUUID.uuid) { Array($0) }, length: 16)
        var hits: [(IOBluetoothDevice, BluetoothRFCOMMChannelID)] = []
        for device in devices {
            guard let record = device.getServiceRecord(for: sdpUUID) else {
                out("[2] 「\(device.name ?? "?")」无中转服务")
                continue
            }
            var channelID: BluetoothRFCOMMChannelID = 0
            record.getRFCOMMChannelID(&channelID)
            out("[2] ✓ 「\(device.name ?? "?")」有中转服务，RFCOMM 通道 \(channelID)")
            hits.append((device, channelID))
        }

        guard let (phone, channelID) = hits.first else {
            out("[3] ✗ 没有任何配对设备提供中转服务。请确认手机 BlueDesk「中转」页已开启服务后重试。")
            return
        }
        out("[3] 对每个命中实例尝试打开 RFCOMM（含 1s 重试）…")
        var opened: (IOBluetoothRFCOMMChannel, String)?
        for (device, channelID) in hits {
            for attempt in 1...2 {
                var channel: IOBluetoothRFCOMMChannel?
                let status = device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: nil)
                if status == kIOReturnSuccess, let ch = channel {
                    out("[4] ✓ 「\(device.name ?? "?")」第 \(attempt) 次打开成功")
                    opened = (ch, device.name ?? "?")
                    break
                }
                out("[4] ✗ 「\(device.name ?? "?")」第 \(attempt) 次失败：0x\(String(UInt32(bitPattern: Int(status)), radix: 16))")
                Thread.sleep(forTimeInterval: 1)
            }
            if opened != nil { break }
        }
        guard let (channel, name) = opened else {
            out("[5] ✗ 所有实例都无法打开 RFCOMM。")
            out("    常见原因：手机端中转服务刚被系统回收（重新开关一次中转服务）、")
            out("    或链路需要先在手机↔Mac 间建立基础连接（手机蓝牙设置里点一下该 Mac）。")
            return
        }
        out("[5] ✓ RFCOMM 通道已打开，发送 HELLO…")

        let hello = Protocol.encode(Protocol.hello(Host.current().localizedName ?? "Mac-Diag"))
        let writeStatus = hello.withUnsafeBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnError }
            return channel.writeSync(UnsafeMutableRawPointer(mutating: base),
                                     length: UInt16(hello.count))
        }
        out("[6] \(writeStatus == kIOReturnSuccess ? "✓" : "✗") HELLO 写入：0x\(String(writeStatus, radix: 16))")
        out("    → 若以上全部 ✓：手机「中转」页应立即出现这台 Mac；若仍没有，看手机端 logcat -s TransferManager")

        sleep(2)
        channel.close()
        out("=== 诊断结束 ===")
    }
}
