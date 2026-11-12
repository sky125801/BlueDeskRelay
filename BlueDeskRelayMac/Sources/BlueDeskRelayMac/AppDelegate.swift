import AppKit
import ApplicationServices
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

    /// 系统通知是否可用；不可用时 [notify] 退回自带浮层
    private var systemNotificationsAllowed = false
    private var statusMenuItem: NSMenuItem!
    private var sendClipItem: NSMenuItem!
    private var sendFileItem: NSMenuItem!
    private var sendSelectedItem: NSMenuItem!
    private var disconnectItem: NSMenuItem!
    private weak var connectSubmenu: NSMenu?
    private var reconnectTimer: Timer?

    /// 手机未连接时先排队的文件，连上后自动补发
    private var pendingFiles: [URL] = []
    /// 上一次的连接状态：数据链路切换也会触发 onStateChange，避免重复弹「已连接」
    private var phoneConnected = false

    private enum HotkeyID: UInt32 {
        case clipboard = 0xBDEC
        case file = 0xBDED
    }

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 没有「辅助功能」授权时 CGEvent 注入会被系统静默丢弃：手机端的 Wi-Fi 输入
        // 车道会收到 ok=0 并主动回落 HID（表现就是「明明同局域网却一直走蓝牙」）。
        // 启动时主动拉起系统授权面板，让用户一步到位；已授权时不会打扰。
        if !ScriptInjector.isTrusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
            NSLog("[BlueDesk Relay] 未获辅助功能授权，已请求系统对话框")
        }

        // 通知授权（收发提示用；denied 时退回自带提示条，功能本体不受影响）
        // 「用浏览器打开」动作注册在这里：手机复制链接时，通知上多一个按钮
        let openLink = UNNotificationAction(identifier: "BD_OPEN_LINK",
                                            title: L10n.t("notify.openLink"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "BD_LINK", actions: [openLink],
                                   intentIdentifiers: [], options: [])
        ])
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { [weak self] granted, _ in
                UNUserNotificationCenter.current().getNotificationSettings { s in
                    let allowed = granted ||
                        s.authorizationStatus == .authorized ||
                        s.authorizationStatus == .provisional
                    DispatchQueue.main.async { self?.systemNotificationsAllowed = allowed }
                }
            }

        // 剪贴板自动同步：Mac 端变化回传手机（手机侧开关关闭时会被忽略）
        startClipboardWatch()

        // 菜单
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: L10n.t("status.notConnected"), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        // 手动连接：展开时动态列出已配对设备
        let connectSub = NSMenu(title: L10n.t("menu.connectDevice"))
        connectSub.delegate = self
        let connectItem = NSMenuItem(title: L10n.t("menu.connectDevice"), action: nil, keyEquivalent: "")
        connectItem.submenu = connectSub
        connectSubmenu = connectSub
        menu.addItem(connectItem)

        disconnectItem = NSMenuItem(title: L10n.t("menu.disconnect"), action: #selector(disconnectPhone), keyEquivalent: "")
        disconnectItem.target = self
        disconnectItem.isEnabled = false
        menu.addItem(disconnectItem)
        menu.addItem(.separator())

        sendClipItem = NSMenuItem(title: L10n.t("menu.sendClipboard"),
                                  action: #selector(sendClipboard), keyEquivalent: "")
        sendClipItem.target = self
        sendClipItem.isEnabled = false
        menu.addItem(sendClipItem)

        sendFileItem = NSMenuItem(title: L10n.t("menu.sendFile"), action: #selector(sendFile), keyEquivalent: "")
        sendFileItem.target = self
        sendFileItem.isEnabled = false
        menu.addItem(sendFileItem)

        // 与 Windows 端 Ctrl+Alt+F 对位：Finder 里选中文件后直接发
        sendSelectedItem = NSMenuItem(title: L10n.t("menu.sendFinderSelection"),
                                      action: #selector(sendFinderSelection), keyEquivalent: "")
        sendSelectedItem.target = self
        sendSelectedItem.isEnabled = false
        menu.addItem(sendSelectedItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.autoenablesItems = false

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                           accessibilityDescription: L10n.t("app.name"))
        installDropTargetOnStatusItem()

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
        // 手机通知镜像：用系统通知展示，应用名 + 标题做抬头，正文做内容
        link.onNotification = { [weak self] json in
            guard let self,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let app = (obj["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let body = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty || !body.isEmpty else { return }
            let head = [app, title].filter { !$0.isEmpty }.joined(separator: " · ")
            self.notify(head.isEmpty ? app : head, body.isEmpty ? title : body)
        }
        // 剪贴板自动同步：手机 → Mac 静默写入系统剪贴板；是网址时额外给一个「用浏览器打开」
        link.onClipboard = { [weak self] text in
            guard let self else { return }
            self.applyClipboard(text)
            if self.httpURL(from: text) != nil { self.notifyLink(text) }
        }
        link.onFile = { [weak self] path, size in
            self?.notify(L10n.t("file.received"),
                         L10n.t("file.receivedBody",
                                FileManager.default.displayName(atPath: path), formatSize(size)))
        }
        link.onFolder = { [weak self] path, count in
            self?.notify(L10n.t("folder.received"),
                         L10n.t("folder.receivedBody",
                                FileManager.default.displayName(atPath: path), count))
        }
        link.onFileSent = { [weak self] name, size in
            self?.notify(L10n.t("file.sent"), L10n.t("file.sentBody", name, formatSize(size)))
        }
        link.onError = { [weak self] message in
            self?.notify(L10n.t("app.name"), message)
        }

        // 自动连接 + 断线重连（加 common mode，拖菜单时不暂停）
        link.connect()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.link.ensureConnected()
        }
        RunLoop.main.add(reconnectTimer!, forMode: .common)
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
                                           MemoryLayout<EventHotKeyID>.size,
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
            notify(L10n.t("hotkey.failed"), L10n.t("hotkey.occupied", name))
        }
    }

    // MARK: - 状态

    private func updateStatus(connected: Bool, name: String) {
        statusMenuItem.title = connected
            ? L10n.t("status.connectedTransport", name, link.transportDescription)
            : L10n.t("status.notConnected")
        sendClipItem.isEnabled = connected
        sendFileItem.isEnabled = connected
        sendSelectedItem.isEnabled = connected
        disconnectItem.isEnabled = connected
        if connected {
            // 数据链路建立/断开也会走到这里，只在真正从断开变成连接时提示
            if !phoneConnected {
                notify(L10n.t("app.name"), L10n.t("status.connected", name))

                // 右键 / 快捷键送来的文件可能在连接前就排队了，这里补发
                if !pendingFiles.isEmpty {
                    let queued = pendingFiles
                    pendingFiles.removeAll()
                    for url in queued { sendFileURL(url) }
                }
            }
        } else if phoneConnected {
            notify(L10n.t("app.name"), L10n.t("status.phoneDisconnected"))
        }
        phoneConnected = connected
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
            let hint = NSMenuItem(title: L10n.t("connect.noDevices"),
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
                item.title = L10n.t("connect.preferred", device.name)
            }
            sub.addItem(item)
        }

        sub.addItem(.separator())
        let reset = NSMenuItem(title: L10n.t("connect.clearPreferred"),
                               action: #selector(clearPreferredDevice), keyEquivalent: "")
        reset.target = self
        sub.addItem(reset)
    }

    @objc private func connectToDevice(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        // 先断开当前连接再切目标
        if link.isConnected { link.disconnect() }
        guard let device = link.pairedDevice(at: address) else {
            notify(L10n.t("connect.failed"), L10n.t("connect.deviceUnpaired"))
            return
        }
        notify(L10n.t("connect.connecting"), L10n.t("connect.connectingFormat", device.name ?? address))
        link.connect(to: device)
    }

    @objc private func clearPreferredDevice() {
        link.clearPreferred()
        notify(L10n.t("preferred.cleared"), L10n.t("preferred.clearedBody"))
    }

    @objc private func disconnectPhone() {
        link.disconnectManual()
    }

    // MARK: - 发送

    @objc private func sendClipboard() {
        guard link.isConnected else {
            notify(L10n.t("error.notConnected"), L10n.t("error.tryAgain"))
            return
        }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if text.isEmpty {
            notify(L10n.t("clipboard.empty"), L10n.t("clipboard.emptyHint"))
            return
        }
        link.sendText(text)
        notify(L10n.t("send.sent"), L10n.t("send.sentBody", text.count))
    }

    @objc private func sendFile() {
        guard link.isConnected else {
            notify(L10n.t("error.notConnected"), L10n.t("error.tryAgain"))
            return
        }
        let panel = NSOpenPanel()
        panel.title = L10n.t("file.select")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)   // accessory 应用需要手动激活才能弹窗
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            if size > 64 * 1024 * 1024 {
                self.notify(L10n.t("file.tooLarge"), L10n.t("file.tooLargeLimit"))
                return
            }
            self.notify(L10n.t("send.sending"), L10n.t("send.sendingBody", url.lastPathComponent))
            self.link.sendFile(at: url)
        }
    }

    // MARK: - 拖拽到菜单栏图标

    /// 在状态栏按钮上盖一层投放层：把文件/文件夹拖到菜单栏图标即发送。
    /// 覆盖层会把点击原样转发给按钮，因此菜单交互不受影响。
    private func installDropTargetOnStatusItem() {
        guard let button = statusItem.button else { return }
        let overlay = StatusDropOverlay(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.button = button
        overlay.onDrop = { [weak self] urls in self?.sendURLs(urls) }
        button.addSubview(overlay)
    }

    // MARK: - Finder 右键「服务」 / 快捷键发送

    /// Finder 右键 → 服务 →「发送到 BlueDesk」的接收方法。
    /// NSMessage 必须与 Info.plist 里的 NSServices.NSMessage 一致。
    @objc func sendFilesToBlueDesk(_ pboard: NSPasteboard, userData: String,
                                   error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = fileURLs(from: pboard)
        guard !urls.isEmpty else {
            error.pointee = L10n.t("service.noFiles") as NSString
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
            notify(L10n.t("noFileSelected"), L10n.t("noFileSelected.hint"))
            return
        }
        sendURLs(urls)
    }

    private func sendURLs(_ urls: [URL]) {
        guard link.isConnected else {
            pendingFiles.append(contentsOf: urls)
            notify(L10n.t("waiting"), L10n.t("waiting.format", urls.count))
            return
        }
        for url in urls { sendFileURL(url) }
    }

    private func sendFileURL(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > 64 * 1024 * 1024 {
            notify(L10n.t("file.tooLarge"), L10n.t("file.tooLargeFormat", url.lastPathComponent))
            return
        }
        notify(L10n.t("send.sending"), L10n.t("send.sendingBody", url.lastPathComponent))
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
        notify(L10n.t("text.received"), L10n.t("text.receivedBody", text.count))
    }

    // MARK: - 剪贴板自动同步

    private var clipboardTimer: Timer?
    /// 上次轮询到的 changeCount：没变化就不读取内容
    private var lastPasteboardChange = 0
    /// 刚由手机写入的内容：轮询再次看到时不再回传，避免两端来回弹
    private var suppressedClipboard: String?

    /// macOS 没有可靠的跨进程剪贴板通知，这里 0.6 秒轮询一次 changeCount；
    /// 只有计数变化时才读字符串，平时开销可以忽略。
    private func startClipboardWatch() {
        lastPasteboardChange = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        if text == suppressedClipboard {
            suppressedClipboard = nil
            return
        }
        suppressedClipboard = nil
        link.sendClipboard(text)
    }

    /// 手机同步来的文本：写入剪贴板，并让轮询忽略这次变化
    private func applyClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        suppressedClipboard = text
        lastPasteboardChange = pasteboard.changeCount
    }

    /// 手机复制的是网址：弹一条带「用浏览器打开」按钮的通知。
    /// 系统通知不可用时退回自带浮层，此时只能提示（内容已在剪贴板里，可直接粘贴）。
    private func notifyLink(_ text: String) {
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard systemNotificationsAllowed else {
            // 兜底浮层没有按钮，但可以点：点一下直接打开
            NotificationHUD.shared.show(title: L10n.t("notify.linkTitle"), body: url) {
                if let target = self.httpURL(from: url) { NSWorkspace.shared.open(target) }
            }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = L10n.t("notify.linkTitle")
        content.body = url
        content.categoryIdentifier = "BD_LINK"
        content.userInfo = ["url": url]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// 只认整条文本就是 http/https 链接的情况，避免把普通句子误判成网址
    fileprivate func httpURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2048,
              !trimmed.contains("\n"),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func notify(_ title: String, _ body: String) {
        // 系统通知被拒（开发签名每次重建都会失效）时改用自带浮层，保证提示可见
        guard systemNotificationsAllowed else {
            NotificationHUD.shared.show(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private func formatSize(_ bytes: Int) -> String {
    ByteSize.human(bytes)
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// 点通知上的「用浏览器打开」；直接点通知本体也按同样处理（横幅上按钮要展开才看得到）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let tappedBody = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let tappedAction = response.actionIdentifier == "BD_OPEN_LINK"
        if (tappedAction || (tappedBody && content.categoryIdentifier == "BD_LINK")),
           let text = content.userInfo["url"] as? String,
           let url = httpURL(from: text) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
