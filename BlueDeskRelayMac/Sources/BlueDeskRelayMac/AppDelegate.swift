import AppKit
import Carbon.HIToolbox
import UserNotifications

/// 菜单栏程序：
///   - 自动连接 BlueDesk 手机（断线 5 秒重试）；
///   - 菜单 / 全局热键发送剪贴板、菜单发送文件；
///   - Finder 右键「服务」与 Ctrl+Opt+F 直接发送选中文件（与 Windows 端对位）；
///   - 收文本写剪贴板（中文原样），收文件落 Downloads/BlueDesk，均有气泡通知。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let link = PhoneLink()

    private var statusMenuItem: NSMenuItem!
    private var sendClipItem: NSMenuItem!
    private var sendFileItem: NSMenuItem!
    private var sendSelectedItem: NSMenuItem!
    private var disconnectItem: NSMenuItem!
    private weak var connectSubmenu: NSMenu?
    private var reconnectTimer: Timer?

    /// 手机未连接时先排队的文件，连上后自动补发
    private var pendingFiles: [URL] = []

    private enum HotkeyID: UInt32 {
        case clipboard = 0xBDEC
        case file = 0xBDED
    }

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 通知授权（收发提示用；denied 不影响功能本体）
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { _, _ in }

        // 菜单
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "未连接（自动重连中）", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        // 手动连接：展开时动态列出已配对设备
        let connectSub = NSMenu(title: "连接设备")
        connectSub.delegate = self
        let connectItem = NSMenuItem(title: "连接设备", action: nil, keyEquivalent: "")
        connectItem.submenu = connectSub
        connectSubmenu = connectSub
        menu.addItem(connectItem)

        disconnectItem = NSMenuItem(title: "断开连接", action: #selector(disconnectPhone), keyEquivalent: "")
        disconnectItem.target = self
        disconnectItem.isEnabled = false
        menu.addItem(disconnectItem)
        menu.addItem(.separator())

        sendClipItem = NSMenuItem(title: "发送剪贴板内容 (Ctrl+Opt+B)",
                                  action: #selector(sendClipboard), keyEquivalent: "")
        sendClipItem.target = self
        sendClipItem.isEnabled = false
        menu.addItem(sendClipItem)

        sendFileItem = NSMenuItem(title: "发送文件…", action: #selector(sendFile), keyEquivalent: "")
        sendFileItem.target = self
        sendFileItem.isEnabled = false
        menu.addItem(sendFileItem)

        // 与 Windows 端 Ctrl+Alt+F 对位：Finder 里选中文件后直接发
        sendSelectedItem = NSMenuItem(title: "发送 Finder 选中的文件 (Ctrl+Opt+F)",
                                      action: #selector(sendFinderSelection), keyEquivalent: "")
        sendSelectedItem.target = self
        sendSelectedItem.isEnabled = false
        menu.addItem(sendSelectedItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.autoenablesItems = false

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                           accessibilityDescription: "BlueDesk 互传助手")

        // Finder 右键「服务」菜单的接收方（对应 Windows 资源管理器右键菜单）
        NSApp.servicesProvider = self

        // 全局热键：Ctrl+Opt+B 发剪贴板，Ctrl+Opt+F 发 Finder 选中文件
        installHotKeys()

        // 手机侧回调
        link.onStateChange = { [weak self] connected, name in
            self?.updateStatus(connected: connected, name: name)
        }
        link.onText = { [weak self] text in
            self?.receiveText(text)
        }
        link.onFile = { [weak self] path, size in
            self?.notify("收到文件", "\(FileManager.default.displayName(atPath: path))（\(formatSize(size))）已保存到 Downloads/BlueDesk")
        }
        link.onError = { [weak self] message in
            self?.notify("BlueDesk 互传助手", message)
        }

        // 自动连接 + 断线重连
        link.connect()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.link.ensureConnected()
        }
    }

    // MARK: - 全局热键

    /// 注册两枚 Carbon 热键，并由同一个事件处理器按 EventHotKeyID 分发
    private func installHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // 无捕获闭包，实例通过 userData 指针传回
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           UInt32(MemoryLayout<EventHotKeyID>.size),
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }

            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            switch HotkeyID(rawValue: hotKeyID.id) {
            case .clipboard: DispatchQueue.main.async { delegate.sendClipboard() }
            case .file: DispatchQueue.main.async { delegate.sendFinderSelection() }
            case .none: return OSStatus(eventNotHandledErr)
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)

        registerHotKey(UInt32(kVK_ANSI_B), id: .clipboard)
        registerHotKey(UInt32(kVK_ANSI_F), id: .file)
    }

    private func registerHotKey(_ keyCode: UInt32, id: HotkeyID) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(controlKey | optionKey),
            EventHotKeyID(signature: OSType(0x4244534B), id: id.rawValue),
            GetApplicationEventTarget(),
            0,
            &ref)

        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            let name = id == .clipboard ? "Ctrl+Opt+B" : "Ctrl+Opt+F"
            notify("热键注册失败", "\(name) 可能被其他程序占用，请改用菜单发送")
        }
    }

    // MARK: - 状态

    private func updateStatus(connected: Bool, name: String) {
        statusMenuItem.title = connected ? "已连接 \(name)" : "未连接（自动重连中）"
        sendClipItem.isEnabled = connected
        sendFileItem.isEnabled = connected
        sendSelectedItem.isEnabled = connected
        disconnectItem.isEnabled = connected
        if connected {
            notify("BlueDesk 互传助手", "已连接 \(name)")

            // 右键 / 快捷键送来的文件可能在连接前就排队了，这里补发
            if !pendingFiles.isEmpty {
                let queued = pendingFiles
                pendingFiles.removeAll()
                for url in queued { sendFileURL(url) }
            }
        } else {
            notify("BlueDesk 互传助手", "手机连接已断开")
        }
    }

    // MARK: - NSMenuDelegate（「连接设备」子菜单展开时动态重建）

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === connectSubmenu {
            rebuildConnectSubmenu()
        }
    }

    // MARK: - 手动连接（连接设备子菜单）

    /// 子菜单每次展开时重建：列出全部已配对设备，打勾当前连接/记忆的设备
    private func rebuildConnectSubmenu() {
        guard let sub = connectSubmenu else { return }
        sub.removeAllItems()

        let devices = link.pairedDeviceList()
        if devices.isEmpty {
            let hint = NSMenuItem(title: "无已配对设备（先在系统设置→蓝牙配对）",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
            return
        }

        let connectedAddress = link.connectedAddress
        let preferred = link.preferredAddress

        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(connectToDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.address
            if device.address == connectedAddress {
                item.state = .on
            } else if device.address == preferred && !link.isConnected {
                // 记忆设备：用符号标注而非打勾（打勾保留给「正在连接」）
                item.title = "★ \(device.name)（记忆）"
            }
            sub.addItem(item)
        }

        sub.addItem(.separator())
        let reset = NSMenuItem(title: "清除记忆（恢复自动发现 BlueDesk*）",
                               action: #selector(clearPreferredDevice), keyEquivalent: "")
        reset.target = self
        sub.addItem(reset)
    }

    @objc private func connectToDevice(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        // 先断开当前连接再切目标
        if link.isConnected { link.disconnect() }
        guard let device = link.pairedDevice(at: address) else {
            notify("连接失败", "设备可能已取消配对")
            return
        }
        notify("连接中", "正在连接「\(device.name ?? address)」…")
        link.connect(to: device)
    }

    @objc private func clearPreferredDevice() {
        link.clearPreferred()
        notify("已清除记忆", "下次将自动连接第一台 BlueDesk 手机")
    }

    @objc private func disconnectPhone() {
        link.disconnectManual()
    }

    // MARK: - 发送

    @objc private func sendClipboard() {
        guard link.isConnected else {
            notify("未连接", "正在连接手机，稍后重试")
            return
        }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if text.isEmpty {
            notify("剪贴板为空", "先复制一段文字再发送")
            return
        }
        link.sendText(text)
        notify("已发送", "\(text.count) 字符已交给手机")
    }

    @objc private func sendFile() {
        guard link.isConnected else {
            notify("未连接", "正在连接手机，稍后重试")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择要发送的文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)   // accessory 应用需要手动激活才能弹窗
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            if size > 64 * 1024 * 1024 {
                self.notify("文件过大", "单文件上限 64 MB")
                return
            }
            self.notify("发送中", "\(url.lastPathComponent) 传输中…")
            self.link.sendFile(at: url)
        }
    }

    // MARK: - Finder 右键「服务」 / 快捷键发送

    /// Finder 右键 → 服务 →「发送到 BlueDesk」的接收方法。
    /// NSMessage 必须与 Info.plist 里的 NSServices.NSMessage 一致。
    @objc func sendFilesToBlueDesk(_ pboard: NSPasteboard, userData: String,
                                   error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = fileURLs(from: pboard)
        guard !urls.isEmpty else {
            error.pointee = "没有可发送的文件" as NSString
            return
        }
        sendURLs(urls)
    }

    /// 全局热键 Ctrl+Opt+F：优先读 Finder 当前选中项，
    /// 前台不是 Finder 或没有自动化权限时，退回剪贴板里 Cmd+C 复制的文件。
    @objc private func sendFinderSelection() {
        var urls = finderSelection()
        if urls.isEmpty { urls = fileURLs(from: NSPasteboard.general) }

        guard !urls.isEmpty else {
            notify("没有选中文件",
                   "先在 Finder 里选中文件再按 Ctrl+Opt+F；也可以 Cmd+C 复制文件后按")
            return
        }
        sendURLs(urls)
    }

    private func sendURLs(_ urls: [URL]) {
        guard link.isConnected else {
            pendingFiles.append(contentsOf: urls)
            notify("等待连接", "\(urls.count) 个文件已排队，连上手机后自动发送")
            return
        }
        for url in urls { sendFileURL(url) }
    }

    private func sendFileURL(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > 64 * 1024 * 1024 {
            notify("文件过大", "\(url.lastPathComponent) 超过单文件上限 64 MB")
            return
        }
        notify("发送中", "\(url.lastPathComponent) 传输中…")
        link.sendFile(at: url)
    }

    /// AppleScript 读 Finder 选中项（首次使用会弹「自动化」授权）
    private func finderSelection() -> [URL] {
        let source = """
        tell application "Finder"
            set sel to selection
            if (count of sel) is 0 then return ""
            set out to ""
            repeat with f in sel
                set out to out & (POSIX path of (f as alias)) & linefeed
            end repeat
            return out
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return [] }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            NSLog("[AppDelegate] 读取 Finder 选中项失败：\(errorInfo)")
            return []
        }

        let text = result.stringValue ?? ""
        return text.split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && !$0.hasDirectoryPath }
    }

    /// 从粘贴板读文件 URL（右键服务与剪贴板回退共用）
    private func fileURLs(from pboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) && !$0.hasDirectoryPath }
    }

    // MARK: - 接收

    private func receiveText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notify("收到文本", "已写入剪贴板（\(text.count) 字符），可直接 Cmd+V")
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private func formatSize(_ bytes: Int) -> String {
    if bytes >= 1024 * 1024 {
        String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    } else if bytes >= 1024 {
        String(format: "%.1f KB", Double(bytes) / 1024)
    } else {
        "\(bytes) B"
    }
}
