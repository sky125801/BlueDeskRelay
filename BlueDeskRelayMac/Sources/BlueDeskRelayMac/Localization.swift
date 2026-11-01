import Foundation

/// 多语言文案表。
///
/// 设计说明：本程序是菜单栏小工具，文案量约 50 条，且以 `swift build` 直跑可执行文件
/// （不经 .app 打包）为常见调试方式。因此 UI 文案内嵌在 Swift 里，不依赖
/// Contents/Resources 下的 Localizable.strings —— 直跑时不会出现裸 key。
///
/// 系统级文案（蓝牙 / 通知 / 自动化的授权提示、Finder 服务菜单名）必须在 bundle 级
/// 本地化，仍放在 `Resources/<lang>.lproj/InfoPlist.strings`，由 bundle.sh 拷入 app。
///
/// 语言按系统偏好列表逐项匹配，支持 zh / en / ja / ko，其余回退英文。
enum L10n {

    enum Lang: String, CaseIterable {
        case zh, en, ja, ko
    }

    /// 当前激活语言（启动时判定一次）
    static let active: Lang = detect()

    private static func detect() -> Lang {
        for id in Locale.preferredLanguages {
            let lower = id.lowercased()
            if lower.hasPrefix("zh") { return .zh }
            if lower.hasPrefix("ja") { return .ja }
            if lower.hasPrefix("ko") { return .ko }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }

    /// 取文案；`args` 用于 String(format:) 占位替换。
    /// 缺失 key 时回退英文，再回退 key 本身（便于发现遗漏）。
    static func t(_ key: String, _ args: CVarArg...) -> String {
        let template = table[active]?[key] ?? table[.en]?[key] ?? key
        guard !args.isEmpty else { return template }
        return String(format: template, arguments: args)
    }

    // MARK: - 文案表

    private static let table: [Lang: [String: String]] = [

        // ---------------- 简体中文（基准） ----------------
        .zh: [
            "app.name": "BlueDesk 互传助手",

            "status.connected": "已连接 %@",
            "status.notConnected": "未连接（自动重连中）",
            "status.phoneDisconnected": "手机连接已断开",

            "menu.connectDevice": "连接设备",
            "menu.disconnect": "断开连接",
            "menu.sendClipboard": "发送剪贴板内容 (Ctrl+Opt+B)",
            "menu.sendFile": "发送文件…",
            "menu.sendFinderSelection": "发送 Finder 选中的文件 (Ctrl+Opt+F)",
            "menu.quit": "退出",

            "connect.noDevices": "无已配对设备（先在系统设置→蓝牙配对）",
            "connect.preferred": "★ %@（记忆）",
            "connect.clearPreferred": "清除记忆（恢复自动发现 BlueDesk*）",
            "connect.connecting": "连接中",
            "connect.connectingFormat": "正在连接「%@」…",
            "connect.failed": "连接失败",
            "connect.deviceUnpaired": "设备可能已取消配对",
            "preferred.cleared": "已清除记忆",
            "preferred.clearedBody": "下次将自动连接第一台 BlueDesk 手机",

            "hotkey.failed": "热键注册失败",
            "hotkey.occupied": "%@ 可能被其他程序占用，请改用菜单发送",

            "error.notConnected": "未连接",
            "error.tryAgain": "正在连接手机，稍后重试",
            "error.readFileFailed": "读取文件失败",
            "error.sizeOutOfRange": "文件大小超限或未知",
            "error.metaParseFailed": "文件元信息解析失败",
            "error.saveFailed": "保存文件失败：%@",
            "error.noRelayService": "「%@」未提供中转服务，请在手机上打开 BlueDesk → 中转 → 开启中转服务",
            "error.connectFailed": "连接「%@」失败（请确认手机端中转服务已开启）",

            "clipboard.empty": "剪贴板为空",
            "clipboard.emptyHint": "先复制一段文字再发送",

            "send.sent": "已发送",
            "send.sentBody": "%ld 字符已交给手机",
            "send.sending": "发送中",
            "send.sendingBody": "%@ 传输中…",

            "file.tooLarge": "文件过大",
            "file.tooLargeLimit": "单文件上限 64 MB",
            "file.tooLargeFormat": "%@ 超过单文件上限 64 MB",
            "file.select": "选择要发送的文件",

            "noFileSelected": "没有选中文件",
            "noFileSelected.hint": "先在 Finder 里选中文件再按 Ctrl+Opt+F；也可以 Cmd+C 复制文件后按",

            "waiting": "等待连接",
            "waiting.format": "%ld 个文件已排队，连上手机后自动发送",

            "file.received": "收到文件",
            "file.receivedBody": "%@（%@）已保存到 Downloads/BlueDesk",
            "text.received": "收到文本",
            "text.receivedBody": "已写入剪贴板（%ld 字符），可直接 Cmd+V",

            "service.noFiles": "没有可发送的文件",
        ],

        // ---------------- English ----------------
        .en: [
            "app.name": "BlueDesk Relay",

            "status.connected": "Connected to %@",
            "status.notConnected": "Not connected (reconnecting)",
            "status.phoneDisconnected": "Phone connection lost",

            "menu.connectDevice": "Connect Device",
            "menu.disconnect": "Disconnect",
            "menu.sendClipboard": "Send Clipboard (Ctrl+Opt+B)",
            "menu.sendFile": "Send File…",
            "menu.sendFinderSelection": "Send Finder Selection (Ctrl+Opt+F)",
            "menu.quit": "Quit",

            "connect.noDevices": "No paired devices (pair in System Settings > Bluetooth first)",
            "connect.preferred": "★ %@ (preferred)",
            "connect.clearPreferred": "Clear preferred (auto-discover BlueDesk*)",
            "connect.connecting": "Connecting",
            "connect.connectingFormat": "Connecting to \"%@\"…",
            "connect.failed": "Connection failed",
            "connect.deviceUnpaired": "The device may have been unpaired",
            "preferred.cleared": "Preferred device cleared",
            "preferred.clearedBody": "The first BlueDesk phone will be auto-connected next time",

            "hotkey.failed": "Hotkey registration failed",
            "hotkey.occupied": "%@ may be used by another app, please use the menu instead",

            "error.notConnected": "Not connected",
            "error.tryAgain": "Connecting to phone, try again shortly",
            "error.readFileFailed": "Failed to read file",
            "error.sizeOutOfRange": "File size out of range or unknown",
            "error.metaParseFailed": "Failed to parse file metadata",
            "error.saveFailed": "Failed to save file: %@",
            "error.noRelayService": "\"%@\" does not provide the relay service. Open BlueDesk on your phone, go to Relay and turn on the service.",
            "error.connectFailed": "Failed to connect to \"%@\" (make sure the relay service is enabled on your phone)",

            "clipboard.empty": "Clipboard is empty",
            "clipboard.emptyHint": "Copy some text first before sending",

            "send.sent": "Sent",
            "send.sentBody": "%ld characters sent to phone",
            "send.sending": "Sending",
            "send.sendingBody": "%@ transferring…",

            "file.tooLarge": "File too large",
            "file.tooLargeLimit": "Single file limit is 64 MB",
            "file.tooLargeFormat": "%@ exceeds the 64 MB single file limit",
            "file.select": "Select file to send",

            "noFileSelected": "No file selected",
            "noFileSelected.hint": "Select a file in Finder then press Ctrl+Opt+F; or copy a file with Cmd+C and press",

            "waiting": "Waiting for connection",
            "waiting.format": "%ld file(s) queued, will send when the phone connects",

            "file.received": "File received",
            "file.receivedBody": "%@ (%@) saved to Downloads/BlueDesk",
            "text.received": "Text received",
            "text.receivedBody": "Copied to clipboard (%ld chars), Cmd+V to paste",

            "service.noFiles": "No files to send",
        ],

        // ---------------- 日本語 ----------------
        .ja: [
            "app.name": "BlueDesk リレー",

            "status.connected": "%@ に接続済み",
            "status.notConnected": "未接続（自動再接続中）",
            "status.phoneDisconnected": "スマホとの接続が切断されました",

            "menu.connectDevice": "デバイス接続",
            "menu.disconnect": "接続を切断",
            "menu.sendClipboard": "クリップボードを送信 (Ctrl+Opt+B)",
            "menu.sendFile": "ファイルを送信…",
            "menu.sendFinderSelection": "Finder の選択項目を送信 (Ctrl+Opt+F)",
            "menu.quit": "終了",

            "connect.noDevices": "ペアリング済みデバイスがありません（システム設定→Bluetooth でペアリング）",
            "connect.preferred": "★ %@（記憶）",
            "connect.clearPreferred": "記憶をクリア（BlueDesk* の自動検出に戻す）",
            "connect.connecting": "接続中",
            "connect.connectingFormat": "「%@」に接続中…",
            "connect.failed": "接続に失敗しました",
            "connect.deviceUnpaired": "デバイスのペアリングが解除された可能性があります",
            "preferred.cleared": "記憶をクリアしました",
            "preferred.clearedBody": "次回は最初の BlueDesk スマホに自動接続します",

            "hotkey.failed": "ホットキー登録に失敗しました",
            "hotkey.occupied": "%@ は他のアプリが使用している可能性があります。メニューから送信してください",

            "error.notConnected": "未接続",
            "error.tryAgain": "スマホに接続中です。しばらくしてから再試行してください",
            "error.readFileFailed": "ファイルの読み込みに失敗しました",
            "error.sizeOutOfRange": "ファイルサイズが上限超過または不明です",
            "error.metaParseFailed": "ファイルのメタ情報を解析できません",
            "error.saveFailed": "ファイルの保存に失敗しました：%@",
            "error.noRelayService": "「%@」はリレーサービスを提供していません。スマホで BlueDesk を開き、「リレー」でサービスを有効にしてください",
            "error.connectFailed": "「%@」への接続に失敗しました（スマホ側のリレーサービスが有効か確認してください）",

            "clipboard.empty": "クリップボードが空です",
            "clipboard.emptyHint": "テキストをコピーしてから送信してください",

            "send.sent": "送信しました",
            "send.sentBody": "%ld 文字をスマホに送信しました",
            "send.sending": "送信中",
            "send.sendingBody": "%@ 転送中…",

            "file.tooLarge": "ファイルが大きすぎます",
            "file.tooLargeLimit": "1ファイルの上限は 64 MB です",
            "file.tooLargeFormat": "%@ は1ファイルの上限 64 MB を超えています",
            "file.select": "送信するファイルを選択",

            "noFileSelected": "ファイルが選択されていません",
            "noFileSelected.hint": "Finder でファイルを選択して Ctrl+Opt+F を押すか、Cmd+C でコピーしてから押してください",

            "waiting": "接続待機中",
            "waiting.format": "%ld 個のファイルを待機中です。接続後に自動送信します",

            "file.received": "ファイルを受信しました",
            "file.receivedBody": "%@（%@）を Downloads/BlueDesk に保存しました",
            "text.received": "テキストを受信しました",
            "text.receivedBody": "クリップボードに書き込みました（%ld 文字）。Cmd+V で貼り付けできます",

            "service.noFiles": "送信できるファイルがありません",
        ],

        // ---------------- 한국어 ----------------
        .ko: [
            "app.name": "BlueDesk 릴레이",

            "status.connected": "%@에 연결됨",
            "status.notConnected": "연결되지 않음 (재연결 중)",
            "status.phoneDisconnected": "폰 연결이 끊어졌습니다",

            "menu.connectDevice": "기기 연결",
            "menu.disconnect": "연결 해제",
            "menu.sendClipboard": "클립보드 전송 (Ctrl+Opt+B)",
            "menu.sendFile": "파일 전송…",
            "menu.sendFinderSelection": "Finder 선택 항목 전송 (Ctrl+Opt+F)",
            "menu.quit": "종료",

            "connect.noDevices": "페어링된 기기 없음 (시스템 설정 → 블루투스에서 먼저 페어링)",
            "connect.preferred": "★ %@ (선호)",
            "connect.clearPreferred": "선호 기기 삭제 (BlueDesk* 자동 검색으로 복귀)",
            "connect.connecting": "연결 중",
            "connect.connectingFormat": "\"%@\"에 연결 중…",
            "connect.failed": "연결 실패",
            "connect.deviceUnpaired": "기기 페어링이 해제되었을 수 있습니다",
            "preferred.cleared": "선호 기기가 삭제되었습니다",
            "preferred.clearedBody": "다음에는 첫 번째 BlueDesk 폰에 자동 연결됩니다",

            "hotkey.failed": "단축키 등록 실패",
            "hotkey.occupied": "%@이(가) 다른 앱에서 사용 중일 수 있습니다. 메뉴에서 전송하세요",

            "error.notConnected": "연결되지 않음",
            "error.tryAgain": "폰에 연결 중입니다. 잠시 후 다시 시도하세요",
            "error.readFileFailed": "파일을 읽지 못했습니다",
            "error.sizeOutOfRange": "파일 크기가 한도를 초과했거나 알 수 없습니다",
            "error.metaParseFailed": "파일 메타 정보를 분석하지 못했습니다",
            "error.saveFailed": "파일 저장 실패: %@",
            "error.noRelayService": "\"%@\"이(가) 릴레이 서비스를 제공하지 않습니다. 폰에서 BlueDesk를 열고 '릴레이'에서 서비스를 켜세요",
            "error.connectFailed": "\"%@\" 연결 실패 (폰의 릴레이 서비스가 켜져 있는지 확인하세요)",

            "clipboard.empty": "클립보드가 비어 있습니다",
            "clipboard.emptyHint": "텍스트를 먼저 복사한 후 전송하세요",

            "send.sent": "전송됨",
            "send.sentBody": "%ld자를 폰으로 전송했습니다",
            "send.sending": "전송 중",
            "send.sendingBody": "%@ 전송 중…",

            "file.tooLarge": "파일이 너무 큽니다",
            "file.tooLargeLimit": "단일 파일 한도는 64 MB입니다",
            "file.tooLargeFormat": "%@이(가) 단일 파일 한도 64 MB를 초과합니다",
            "file.select": "전송할 파일 선택",

            "noFileSelected": "선택된 파일 없음",
            "noFileSelected.hint": "Finder에서 파일을 선택한 후 Ctrl+Opt+F를 누르거나, Cmd+C로 파일을 복사한 후 누르세요",

            "waiting": "연결 대기 중",
            "waiting.format": "%ld개 파일이 대기 중입니다. 폰 연결 후 자동 전송됩니다",

            "file.received": "파일 수신",
            "file.receivedBody": "%@ (%@)이(가) Downloads/BlueDesk에 저장되었습니다",
            "text.received": "텍스트 수신",
            "text.receivedBody": "클립보드에 복사됨 (%ld자), Cmd+V로 붙여넣기",

            "service.noFiles": "전송할 파일이 없습니다",
        ],
    ]
}
