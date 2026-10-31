import AppKit

// BlueDesk 中转助手（macOS）—— 菜单栏入口
// 诊断模式：--diag 参数，或存在 /tmp/bluedesk-diag-trigger 触发文件（open 启动场景）
let diagArgs = CommandLine.arguments.contains("--diag")
let diagTrigger = FileManager.default.fileExists(atPath: "/tmp/bluedesk-diag-trigger")
if diagArgs || diagTrigger {
    if diagTrigger { try? FileManager.default.removeItem(atPath: "/tmp/bluedesk-diag-trigger") }
    Diagnostics.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
