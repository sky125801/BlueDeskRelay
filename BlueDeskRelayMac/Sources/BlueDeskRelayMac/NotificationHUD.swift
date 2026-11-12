import AppKit

/// 轻量提示条：系统通知权限不可用时的兜底。
///
/// 开发构建每次重新打包签名都会变化，macOS 会把新二进制当成「另一个应用」，
/// 通知权限于是长期停在 denied。此时 UNUserNotificationCenter 会静默丢弃通知，
/// 用户完全无感知；这里用右上角浮层保证提示一定能看到。
///
/// 不加焦点、不拦截鼠标、不进入 Dock 切换，4.5 秒后淡出，风格与菜单栏工具一致。
final class NotificationHUD {

    static let shared = NotificationHUD()

    private static let width: CGFloat = 320
    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 8

    private var panels: [NSPanel] = []

    private init() {}

    func show(title: String, body: String) {
        if Thread.isMainThread {
            present(title: title, body: body)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.present(title: title, body: body)
            }
        }
    }

    private func present(title: String, body: String) {
        let hasBody = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let height: CGFloat = hasBody ? 72 : 48

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let effect = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: Self.width, height: height)
        )
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(
            x: 14,
            y: hasBody ? height - 32 : (height - 18) / 2,
            width: Self.width - 28,
            height: 18
        )
        effect.addSubview(titleLabel)

        if hasBody {
            let bodyLabel = NSTextField(labelWithString: body)
            bodyLabel.font = .systemFont(ofSize: 12)
            bodyLabel.textColor = .secondaryLabelColor
            bodyLabel.lineBreakMode = .byTruncatingTail
            bodyLabel.maximumNumberOfLines = 2
            bodyLabel.frame = NSRect(x: 14, y: 12, width: Self.width - 28, height: 32)
            effect.addSubview(bodyLabel)
        }

        panel.contentView = effect
        position(panel, height: height)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panels.append(panel)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self, weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                self?.panels.removeAll { $0 === panel }
            })
        }
    }

    /// 右上角向下堆叠：新提示压在已有提示下面，避免互相遮挡
    private func position(_ panel: NSPanel, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var top = visible.maxY - Self.margin
        for shown in panels { top -= shown.frame.height + Self.gap }
        panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.width - Self.margin, y: top - height))
    }
}
