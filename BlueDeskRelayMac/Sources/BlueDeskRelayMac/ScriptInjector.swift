import ApplicationServices
import CoreGraphics
import Foundation

/// 脚本步骤执行器 —— 手机下发步骤后，由本机用 CGEvent 直接注入。
///
/// 与 HID 通道相比：
///   - 鼠标按屏幕绝对坐标定位，不依赖相对位移累积与归零校准；
///   - 文本走 Unicode 注入，中文 / emoji / 任意字符都不受键盘布局限制；
///   - 每步返回真实结果，手机据此判断成功或失败。
///
/// 需要「系统设置 → 隐私与安全性 → 辅助功能」授权；未授权时事件会被系统丢弃，
/// 所以这里先检查 AXIsProcessTrusted()，未授权直接报错而不是假装成功。
enum ScriptInjector {

    /// 与手机端 HidCommandExecutor 的逻辑坐标一致
    static let logicalWidth: CGFloat = 1280
    static let logicalHeight: CGFloat = 720

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 注入事件的水印：录制器据此跳过自身产生的输入，避免边跑边录时自我回放
    static let injectedTag: Int64 = 0x424C_5545

    enum InjectError: LocalizedError {
        case noPermission
        case unknownStep(String)
        case unknownKey(String)

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能"
            case .unknownStep(let t):
                return "未知步骤类型「\(t)」"
            case .unknownKey(let k):
                return "无法识别的按键「\(k)」"
            }
        }
    }

    /// 执行一条 SCRIPT_STEP 载荷
    static func execute(_ step: [String: Any]) throws {
        guard isTrusted else { throw InjectError.noPermission }

        let type = step["t"] as? String ?? ""
        switch type {
        case "move":
            move(to: point(step))
        case "click":
            move(to: point(step))
            Thread.sleep(forTimeInterval: 0.02)
            try click(at: point(step), button: .left)
        case "rclick":
            move(to: point(step))
            Thread.sleep(forTimeInterval: 0.02)
            try click(at: point(step), button: .right)
        case "dclick":
            move(to: point(step))
            Thread.sleep(forTimeInterval: 0.02)
            try click(at: point(step), button: .left, clicks: 1)
            Thread.sleep(forTimeInterval: 0.04)
            try click(at: point(step), button: .left, clicks: 2)
        case "wheel":
            scroll(amount: intValue(step, "w", fallback: 5))
        case "key", "combo":
            try keyCombo(step["k"] as? String ?? "")
        case "type":
            try typeText(step["txt"] as? String ?? "")
        case "wait", "loop", "end":
            break
        default:
            throw InjectError.unknownStep(type)
        }
    }

    // MARK: - 实时输入（Wi-Fi 输入车道）

    /// 应用一批 LIVE_INPUT，返回（批次序号, 是否全部注入成功）。
    ///
    /// 与脚本共用同一套 CGEvent 原语：录制/回放与手机实时控制的按键、滚轮语义一致，
    /// 区别只在于实时输入用相对位移（保留系统指针加速），且不逐条回执。
    static func applyLive(_ obj: [String: Any]) -> (Int64, Bool) {
        let seq = (obj["seq"] as? NSNumber)?.int64Value ?? 0
        guard isTrusted else { return (seq, false) }
        var ok = true
        for ev in (obj["ev"] as? [[String: Any]]) ?? [] {
            let type = ev["t"] as? String ?? ""
            do {
                switch type {
                case "move":
                    try moveRelative(dx: intValue(ev, "dx", fallback: 0),
                                     dy: intValue(ev, "dy", fallback: 0))
                case "down":
                    try button(down: true, right: (ev["b"] as? Int) == 2)
                case "up":
                    try button(down: false, right: (ev["b"] as? Int) == 2)
                case "wheel":
                    scroll(amount: intValue(ev, "d", fallback: 0))
                case "key":
                    try keyCombo(ev["k"] as? String ?? "")
                case "text":
                    try typeText(ev["s"] as? String ?? "")
                default:
                    break
                }
            } catch {
                ok = false
                NSLog("[ScriptInjector] 实时输入失败（\(type)）：\(error.localizedDescription)")
            }
        }
        return (seq, ok)
    }

    /// 相对移动：读当前光标位置再叠加，保留系统的指针加速曲线
    private static func moveRelative(dx: Int, dy: Int) throws {
        guard dx != 0 || dy != 0 else { return }
        let now = CGEvent(source: nil)?.location ?? .zero
        let p = CGPoint(x: now.x + CGFloat(dx), y: now.y + CGFloat(dy))
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: p, mouseButton: .left) else {
            throw InjectError.noPermission
        }
        event.setIntegerValueField(.eventSourceUserData, value: injectedTag)
        event.post(tap: .cghidEventTap)
    }

    private static func button(down: Bool, right: Bool) throws {
        let point = CGEvent(source: nil)?.location ?? .zero
        let type: CGEventType = right
            ? (down ? .rightMouseDown : .rightMouseUp)
            : (down ? .leftMouseDown : .leftMouseUp)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: right ? .right : .left) else {
            throw InjectError.noPermission
        }
        event.setIntegerValueField(.eventSourceUserData, value: injectedTag)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - 坐标与鼠标

    /// 逻辑坐标 → 主屏坐标（与 Windows 端一致：按比例映射）
    private static func point(_ step: [String: Any]) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let x = CGFloat(intValue(step, "x", fallback: 0)) / logicalWidth
        let y = CGFloat(intValue(step, "y", fallback: 0)) / logicalHeight
        return CGPoint(
            x: bounds.origin.x + x * bounds.width,
            y: bounds.origin.y + y * bounds.height
        )
    }

    private static func move(to p: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: p, mouseButton: .left)
        event?.setIntegerValueField(.eventSourceUserData, value: injectedTag)
        event?.post(tap: .cghidEventTap)
    }

    private static func click(at p: CGPoint, button: CGMouseButton, clicks: Int = 1) throws {
        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
        default:
            downType = .leftMouseDown
            upType = .leftMouseUp
        }

        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                 mouseCursorPosition: p, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                               mouseCursorPosition: p, mouseButton: button) else {
            throw InjectError.noPermission
        }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        down.setIntegerValueField(.eventSourceUserData, value: injectedTag)
        up.setIntegerValueField(.eventSourceUserData, value: injectedTag)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.015)
        up.post(tap: .cghidEventTap)
    }

    private static func scroll(amount: Int) {
        guard amount != 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                  wheel1: Int32(amount), wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: injectedTag)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - 键盘

    private static func keyCombo(_ combo: String) throws {
        let parts = combo.split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let mainToken = parts.last else { return }

        var flags: CGEventFlags = []
        for token in parts.dropLast() {
            guard let flag = modifierFlag(token) else {
                throw InjectError.unknownKey(token)
            }
            flags.insert(flag)
        }
        guard let keyCode = keyCode(mainToken) else {
            throw InjectError.unknownKey(mainToken)
        }
        tapKey(keyCode, flags: flags)
    }

    private static func typeText(_ text: String) throws {
        let normalized = text.replacingOccurrences(of: "\r", with: "")
        let lines = normalized.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { tapKey(returnKeyCode, flags: []) }
            guard !line.isEmpty else { continue }
            typeUnicode(line)
        }
    }

    /// 一次性把整段 Unicode 注入当前焦点（无需逐字按键）
    ///
    /// 只把字符串挂在 keyDown 上：keyUp 若也带同一段文本，部分 App 会插入两次，
    /// 另一些则整体忽略。keyUp 需要单独发出，但载荷为空。
    private static func typeUnicode(_ text: String) {
        var units = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.setIntegerValueField(.eventSourceUserData, value: injectedTag)
        down.post(tap: .cghidEventTap)
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            up.setIntegerValueField(.eventSourceUserData, value: injectedTag)
            up.post(tap: .cghidEventTap)
        }
    }

    private static func tapKey(_ code: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: injectedTag)
        up.setIntegerValueField(.eventSourceUserData, value: injectedTag)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.015)
        up.post(tap: .cghidEventTap)
    }

    private static let returnKeyCode: CGKeyCode = 36

    private static func modifierFlag(_ token: String) -> CGEventFlags? {
        switch token.uppercased() {
        case "CTRL", "CONTROL": return .maskControl
        case "ALT", "OPTION": return .maskAlternate
        case "SHIFT": return .maskShift
        case "WIN", "CMD", "COMMAND": return .maskCommand
        default: return nil
        }
    }

    private static func keyCode(_ token: String) -> CGKeyCode? {
        let upper = token.uppercased()
        if let named = namedKeys[upper] { return named }
        if token.count == 1, let ch = token.lowercased().first,
           let code = charKeys[ch] {
            return code
        }
        return nil
    }

    /// 反查：按键码 → 录制器可写入脚本的按键名
    static func token(for code: CGKeyCode) -> String? {
        if let named = namedKeys.first(where: { $0.value == code })?.key { return named }
        if let ch = charKeys.first(where: { $0.value == code })?.key {
            return String(ch).uppercased()
        }
        return nil
    }

    // MARK: - 键位表（ANSI）

    private static let namedKeys: [String: CGKeyCode] = [
        "ENTER": 36, "RETURN": 36, "TAB": 48, "ESC": 53, "ESCAPE": 53,
        "SPACE": 49, "BACKSPACE": 51, "BKSP": 51, "DELETE": 117, "DEL": 117,
        "HOME": 115, "END": 119, "PAGEUP": 116, "PGUP": 116,
        "PAGEDOWN": 121, "PGDN": 121,
        "UP": 126, "DOWN": 125, "LEFT": 123, "RIGHT": 124,
        "CAPSLOCK": 57, "CAPS": 57,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
        "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
    ]

    private static let charKeys: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    // MARK: - 工具

    private static func intValue(_ step: [String: Any], _ key: String, fallback: Int) -> Int {
        if let n = step[key] as? Int { return n }
        if let d = step[key] as? Double { return Int(d) }
        if let s = step[key] as? String, let n = Int(s) { return n }
        return fallback
    }
}
