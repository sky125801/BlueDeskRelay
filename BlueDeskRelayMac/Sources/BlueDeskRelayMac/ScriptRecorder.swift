import CoreGraphics
import Foundation

/// 脚本录制器 —— 用 CGEventTap 抓真实键鼠，生成与手机一致的脚本文件。
///
/// 产出格式与 Windows 端、手机端 `ScriptFileImporter` 完全一致：
/// `{"format":"bluedesk-script","version":1,"name":"…","steps":[…]}`。
/// 坐标换算成 1280×720 逻辑坐标，`d` 是距上一步的间隔毫秒。
///
/// 监听的是 `.cghidEventTap` + `.listenOnly`，不拦截、不修改真实输入；
/// 需要「辅助功能」权限，未授权时 tapCreate 会失败并返回 false。
/// 自身注入的事件带 `ScriptInjector.injectedTag` 水印，会被跳过。
final class ScriptRecorder {

    static let shared = ScriptRecorder()

    private(set) var isRecording = false

    private let logicalWidth: CGFloat = 1280
    private let logicalHeight: CGFloat = 720
    private let maxSteps = 2_000

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var steps: [[String: Any]] = []
    private var heldKeys = Set<Int64>()

    private var lastAt = Date()
    private var lastMoveAt = Date.distantPast
    private var lastClickAt: TimeInterval = 0

    func start() -> Bool {
        guard !isRecording else { return true }
        guard ScriptInjector.isTrusted else { return false }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: scriptRecorderTap,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        runLoopSource = source
        steps.removeAll()
        heldKeys.removeAll()
        lastAt = Date()
        lastMoveAt = .distantPast
        lastClickAt = 0
        isRecording = true
        return true
    }

    /// 结束录制并返回脚本；没有录到步骤返回 nil
    func stop() -> (name: String, scriptJson: String, steps: Int)? {
        guard isRecording else { return nil }
        isRecording = false

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil

        guard !steps.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let name = "录制 \(formatter.string(from: Date()))"

        let payload: [String: Any] = [
            "format": "bluedesk-script",
            "version": 1,
            "name": name,
            "steps": steps,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (name, json, steps.count)
    }

    // MARK: - 事件处理

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        guard isRecording else { return }
        // 跳过自己注入的输入
        if event.getIntegerValueField(.eventSourceUserData) == ScriptInjector.injectedTag {
            return
        }

        switch type {
        case .keyDown:
            onKeyDown(event)
        case .keyUp:
            heldKeys.remove(event.getIntegerValueField(.keyboardEventKeycode))
        case .leftMouseDown:
            onMouseDown(event, type: "click")
        case .rightMouseDown:
            onMouseDown(event, type: "rclick")
        case .scrollWheel:
            onWheel(event)
        case .mouseMoved:
            onMove(event)
        default:
            break
        }
    }

    private func onKeyDown(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard !modifierKeyCodes.contains(code) else { return }
        // 按住不放会连续触发 keyDown，只记第一次
        guard heldKeys.insert(code).inserted else { return }
        guard let token = ScriptInjector.token(for: CGKeyCode(code)) else { return }

        var parts: [String] = []
        let flags = event.flags
        if flags.contains(.maskControl) { parts.append("CTRL") }
        if flags.contains(.maskAlternate) { parts.append("ALT") }
        if flags.contains(.maskShift) { parts.append("SHIFT") }
        if flags.contains(.maskCommand) { parts.append("WIN") }
        parts.append(token)

        append([
            "t": parts.count > 1 ? "combo" : "key",
            "k": parts.joined(separator: "+"),
        ])
    }

    private func onMove(_ event: CGEvent) {
        let now = Date()
        guard now.timeIntervalSince(lastMoveAt) >= 0.04 else { return }
        lastMoveAt = now
        let (x, y) = logicalPoint(event.location)
        append(["t": "move", "x": x, "y": y, "abs": true])
    }

    private func onMouseDown(_ event: CGEvent, type: String) {
        let now = Date().timeIntervalSince1970
        let (x, y) = logicalPoint(event.location)

        // 300ms 内同位置的第二次左键 → 合并成双击
        if type == "click", let last = steps.last,
           last["t"] as? String == "click",
           now - lastClickAt < 0.3,
           abs((last["x"] as? Int ?? 0) - x) <= 6,
           abs((last["y"] as? Int ?? 0) - y) <= 6 {
            var merged = last
            merged["t"] = "dclick"
            merged["d"] = (last["d"] as? Int ?? 0)
                + Int((now - lastAt.timeIntervalSince1970) * 1000)
            steps[steps.count - 1] = merged
            lastAt = Date()
            lastClickAt = 0
            return
        }

        lastClickAt = now
        append(["t": type, "x": x, "y": y, "abs": true])
    }

    private func onWheel(_ event: CGEvent) {
        let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        guard delta != 0 else { return }
        let (x, y) = logicalPoint(event.location)
        append(["t": "wheel", "x": x, "y": y, "w": Int(delta)])
    }

    private func append(_ step: [String: Any]) {
        guard isRecording, steps.count < maxSteps else { return }
        let now = Date()
        var record = step
        let gap = Int(now.timeIntervalSince(lastAt) * 1000)
        record["d"] = min(max(gap, 1), 30_000)
        lastAt = now
        steps.append(record)
    }

    private func logicalPoint(_ location: CGPoint) -> (Int, Int) {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let width = max(1, bounds.width)
        let height = max(1, bounds.height)
        let x = (location.x - bounds.minX) / width * logicalWidth
        let y = (location.y - bounds.minY) / height * logicalHeight
        return (
            min(max(Int(x.rounded()), 0), Int(logicalWidth) - 1),
            min(max(Int(y.rounded()), 0), Int(logicalHeight) - 1)
        )
    }

    private let modifierKeyCodes: Set<Int64> = [55, 56, 57, 58, 59, 61, 62, 63]
}

/// CGEventTap 的 C 回调：转交给录制器实例，原样放行事件
private func scriptRecorderTap(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<ScriptRecorder>.fromOpaque(refcon)
            .takeUnretainedValue()
            .handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
