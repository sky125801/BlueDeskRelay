import AppKit

/// 菜单栏图标的文件投放层。
///
/// NSStatusBarButton 的拖拽接收必须由自定义视图实现，这里在按钮上盖一层透明视图：
///  - 只登记 `fileURL` 拖拽类型，接收文件与文件夹（可多选）；
///  - 普通鼠标事件原样转发给状态栏按钮，菜单的弹出行为保持不变。
final class StatusDropOverlay: NSView {

    weak var button: NSStatusBarButton?

    /// 松手时回调（已过滤为本地文件 URL）
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 点击穿透

    override func mouseDown(with event: NSEvent) { button?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { button?.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { button?.mouseDragged(with: event) }
    override func rightMouseDown(with event: NSEvent) { button?.rightMouseDown(with: event) }

    // MARK: - 拖拽接收

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(from: sender).isEmpty else { return [] }
        button?.highlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        button?.highlight(false)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        button?.highlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let items = urls(from: sender)
        guard !items.isEmpty else { return false }
        onDrop?(items)
        return true
    }

    private func urls(from info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return objects ?? []
    }
}
