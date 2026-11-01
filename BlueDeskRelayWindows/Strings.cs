using System.Globalization;

namespace BlueDeskRelay;

/// <summary>
/// 多语言字符串管理：按系统语言自动选择 zh / en / ja / ko，回退到 en。
/// 所有 UI 文案（菜单项、气泡通知、错误提示）集中在此处。
/// </summary>
internal static class Strings
{
    /// <summary>支持的语言</summary>
    public enum Lang { Zh, En, Ja, Ko }

    /// <summary>当前激活的语言（启动时按系统区域设置自动选择一次）</summary>
    public static Lang Active { get; private set; } = Detect();

    private static Lang Detect()
    {
        var name = CultureInfo.CurrentUICulture.Name.ToLowerInvariant();
        if (name.StartsWith("zh")) return Lang.Zh;
        if (name.StartsWith("ja")) return Lang.Ja;
        if (name.StartsWith("ko")) return Lang.Ko;
        return Lang.En;
    }

    // ---- 字符串 key 列表 ----

    public static string AppTitle => Get("BlueDesk 互传助手", "BlueDesk Relay", "BlueDesk リレー", "BlueDesk 릴레이");
    public static string NotConnected => Get("未连接", "Not connected", "未接続", "연결되지 않음");
    public static string NotConnectedReconnecting => Get("未连接（自动重连中）", "Not connected (reconnecting)", "未接続（自動再接続中）", "연결되지 않음 (재연결 중)");
    public static string ConnectDevice => Get("连接设备", "Connect Device", "デバイス接続", "기기 연결");
    public static string SendClipboard => Get("发送剪贴板内容\tCtrl+Alt+B", "Send Clipboard\tCtrl+Alt+B", "クリップボードを送信\tCtrl+Alt+B", "클립보드 전송\tCtrl+Alt+B");
    public static string SendFile => Get("发送文件…", "Send File…", "ファイル送信…", "파일 전송…");
    public static string SendFolder => Get("发送文件夹…", "Send Folder…", "フォルダ送信…", "폴더 전송…");
    public static string SendSelected => Get("发送资源管理器选中的文件\tCtrl+Alt+F", "Send Explorer Selection\tCtrl+Alt+F", "エクスプローラ選択ファイル送信\tCtrl+Alt+F", "탐색기 선택 파일 전송\tCtrl+Alt+F");
    public static string Quit => Get("退出", "Quit", "終了", "종료");

    // Connection state
    public static string ConnectedFormat => Get("已连接 {0}", "Connected {0}", "接続済み {0}", "연결됨 {0}");
    public static string DisconnectedFormat => Get("连接断开（{0}）", "Disconnected ({0})", "接続切断（{0}）", "연결 끊어짐 ({0})");
    public static string PhoneDisconnectedReconnecting => Get("手机连接已断开，正在重连…", "Phone disconnected, reconnecting…", "スマホ接続が切断されました。再接続中…", "폰 연결이 끊어졌습니다. 재연결 중…");
    public static string TrayConnectedFormat => Get("BlueDesk · 已连接 {0}", "BlueDesk · Connected {0}", "BlueDesk · 接続済み {0}", "BlueDesk · 연결됨 {0}");

    // Text received
    public static string TextReceivedTitle => Get("收到文本", "Text Received", "テキスト受信", "텍스트 수신");
    public static string TextReceivedBodyFormat => Get("已写入剪贴板（{0} 字符），可直接 Ctrl+V", "Copied to clipboard ({0} chars), Ctrl+V to paste", "クリップボードに書き込みました（{0}文字）、Ctrl+Vで貼り付け", "클립보드에 복사됨 ({0}자), Ctrl+V로 붙여넣기");
    public static string ClipboardWriteFailed => Get("写剪贴板失败", "Clipboard write failed", "クリップボード書き込み失敗", "클립보드 쓰기 실패");
    public static string ClipboardBusy => Get("剪贴板被其他程序占用，请稍后重试", "Clipboard is locked by another program, try again later", "クリップボードが他のプログラムに占有されています。後で再試行してください。", "클립보드가 다른 프로그램에 의해 잠겨 있습니다. 나중에 다시 시도하세요.");

    // File received
    public static string FileReceivedTitle => Get("收到文件", "File Received", "ファイル受信", "파일 수신");
    public static string FileReceivedBodyFormat => Get("{0}（{1}）已保存到 {2}", "{0} ({1}) saved to {2}", "{0}（{1}）を{2}に保存しました", "{0} ({1})이(가) {2}에 저장됨");
    public static string FolderReceivedTitle => Get("已接收文件夹", "Folder Received", "フォルダ受信", "폴더 수신");
    public static string FolderReceivedBodyFormat => Get("已接收文件夹 {0}（{1} 个文件）", "Folder {0} received ({1} files)", "フォルダ{0}を受信しました（{1}個のファイル）", "폴더 {0} 수신됨 ({1}개 파일)");

    // Hotkey
    public static string HotkeyFailed => Get("热键注册失败", "Hotkey registration failed", "ホットキー登録失敗", "단축키 등록 실패");
    public static string HotkeyBOccupied => Get("Ctrl+Alt+B 已被其他程序占用，请用托盘菜单发送", "Ctrl+Alt+B is used by another program, use the tray menu", "Ctrl+Alt+Bは他のプログラムに占有されています。トレイメニューを使用してください。", "Ctrl+Alt+B가 다른 프로그램에서 사용 중입니다. 트레이 메뉴를 사용하세요.");
    public static string HotkeyFOccupied => Get("Ctrl+Alt+F 已被其他程序占用，请用托盘菜单发送选中的文件", "Ctrl+Alt+F is used by another program, use the tray menu to send files", "Ctrl+Alt+Fは他のプログラムに占有されています。トレイメニューでファイルを送信してください。", "Ctrl+Alt+F가 다른 프로그램에서 사용 중입니다. 트레이 메뉴로 파일을 전송하세요.");

    // Connect menu
    public static string ReadingPaired => Get("正在读取已配对设备…", "Reading paired devices…", "ペアリング済みデバイスを読み込み中…", "페어링된 기기 읽는 중…");
    public static string NoPairedDevices => Get("无已配对设备（先在系统设置→蓝牙配对）", "No paired devices (pair in System Settings > Bluetooth first)", "ペアリング済みデバイスなし（システム設定→Bluetoothでペアリング）", "페어링된 기기 없음 (시스템 설정 → 블루투스에서 페어링)");
    public static string PreferredMark => Get("★ {0}（记忆）", "★ {0} (preferred)", "★ {0}（記憶）", "★ {0} (선호)");
    public static string RefreshDevices => Get("刷新设备列表", "Refresh device list", "デバイスリスト更新", "기기 목록 새로고침");
    public static string ClearPreferred => Get("清除记忆（恢复自动发现 BlueDesk*）", "Clear preferred (auto-discover BlueDesk*)", "記憶をクリア（自動発見 BlueDesk*に戻す）", "선호 기기 삭제 (BlueDesk* 자동 발견)");
    public static string Connecting => Get("连接中", "Connecting", "接続中", "연결 중");
    public static string ConnectingFormat => Get("正在连接「{0}」…", "Connecting to \"{0}\"…", "「{0}」に接続中…", "\"{0}\"에 연결 중…");
    public static string PreferredCleared => Get("已清除记忆", "Preferred device cleared", "記憶をクリアしました", "선호 기기가 삭제됨");
    public static string PreferredClearedBody => Get("下次将自动连接第一台 BlueDesk 手机", "Will auto-connect to the first BlueDesk phone next time", "次回は最初のBlueDeskスマホに自動接続します", "다음에는 첫 번째 BlueDesk 폰에 자동 연결됩니다");

    // Send
    public static string NotConnectedTryAgain => Get("正在连接手机，稍后重试", "Connecting to phone, try again shortly", "スマホに接続中です。後で再試行してください。", "폰에 연결 중입니다. 잠시 후 재시도하세요.");
    public static string ClipboardEmpty => Get("剪贴板为空", "Clipboard is empty", "クリップボードが空です", "클립보드가 비어 있음");
    public static string ClipboardEmptyHint => Get("先复制一段文字再发送", "Copy some text first before sending", "テキストをコピーしてから送信してください", "텍스트를 먼저 복사한 후 전송하세요");
    public static string SentTitle => Get("已发送", "Sent", "送信済み", "전송됨");
    public static string SentBodyFormat => Get("{0} 字符已交给手机", "{0} chars sent to phone", "{0}文字をスマホに送信しました", "{0}자가 폰으로 전송됨");
    public static string SendFailed => Get("发送失败", "Send failed", "送信失敗", "전송 실패");
    public static string FileTooLarge => Get("文件过大", "File too large", "ファイルが大きすぎます", "파일이 너무 큼");
    public static string FileTooLargeFormat => Get("{0} 超过传输上限 {1}", "{0} exceeds the transfer limit {1}", "{0}は転送上限{1}を超えています", "{0}이(가) 전송 한도 {1}을(를) 초과함");
    public static string SendingTitle => Get("发送中", "Sending", "送信中", "전송 중");
    public static string SendingBodyFormat => Get("{0}（{1}）传输中…", "{0} ({1}) transferring…", "{0}（{1}）転送中…", "{0} ({1}) 전송 중…");
    public static string SelectFile => Get("选择要发送的文件", "Select file to send", "送信するファイルを選択", "전송할 파일 선택");
    public static string SelectFolder => Get("选择要发送的文件夹", "Select folder to send", "送信するフォルダを選択", "전송할 폴더 선택");
    public static string SendingFolderStats => Get("正在统计并发送文件夹…", "Counting and sending folder…", "フォルダを統計して送信中…", "폴더를 집계하여 전송 중…");
    public static string FolderSentTitle => Get("已发送文件夹", "Folder sent", "フォルダ送信済み", "폴더 전송됨");
    public static string FolderSentBodyFormat => Get("{0}（{1} 个文件，{2}）已交给手机{3}", "{0} ({1} files, {2}) sent to phone{3}", "{0}（{1}個のファイル、{2}）をスマホに送信しました{3}", "{0} ({1}개 파일, {2})이(가) 폰으로 전송됨{3}");
    public static string SkippedFormat => Get("，跳过 {0} 个不可读项", ", skipped {0} unreadable items", "、{0}個の読み取れない項目をスキップ", ", 읽을 수 없는 항목 {0}개 건너뜀");
    public static string SendFolderFailed => Get("发送文件夹失败", "Send folder failed", "フォルダ送信失敗", "폴더 전송 실패");

    // Shell send
    public static string WaitingConnection => Get("等待连接", "Waiting for connection", "接続待機", "연결 대기");
    public static string WaitingConnectionFormat => Get("{0} 个文件已排队，连上手机后自动发送", "{0} file(s) queued, will send when phone connects", "{0}個のファイルが待機中。スマホ接続後に自動送信します。", "{0}개 파일이 대기 중입니다. 폰 연결 후 자동 전송됩니다.");
    public static string NotConnectedYet => Get("手机还没连上，暂时无法发送", "Phone not connected yet, cannot send", "スマホがまだ接続されていません。一時的に送信できません。", "폰이 아직 연결되지 않아 일시적으로 전송할 수 없습니다.");
    public static string FileSentBodyFormat => Get("{0} 已交给手机", "{0} sent to phone", "{0}をスマホに送信しました", "{0}이(가) 폰으로 전송됨");
    public static string NoFileSelected => Get("没有选中文件", "No file selected", "ファイルが選択されていません", "선택된 파일 없음");
    public static string NoFileSelectedHint => Get("先在资源管理器里选中文件再按 Ctrl+Alt+F；也可以 Ctrl+C 复制文件后按", "Select a file in Explorer then press Ctrl+Alt+F; or copy a file with Ctrl+C then press", "エクスプローラでファイルを選択してCtrl+Alt+Fを押すか、Ctrl+Cでコピーしてから押してください", "탐색기에서 파일을 선택한 후 Ctrl+Alt+F를 누르거나, Ctrl+C로 파일을 복사한 후 누르세요");

    // Pending files
    public static string ConnectingWillSendFormat => Get("正在连接手机，连接后将发送 {0} 个文件", "Connecting to phone, will send {0} file(s) when connected", "スマホに接続中です。接続後に{0}個のファイルを送信します。", "폰에 연결 중입니다. 연결 후 {0}개 파일을 전송합니다.");

    // Explorer menu
    public static string SendToBlueDesk => Get("发送到 BlueDesk", "Send to BlueDesk", "BlueDeskに送信", "BlueDesk로 전송");

    // Single instance messages
    public static string AlreadyRunningTransferFailed => Get("BlueDesk 互传助手已在运行，但没能把文件交给它。\n请改用托盘图标右键的「发送文件…」。", "BlueDesk Relay is already running but could not receive the files.\nUse the tray icon right-click \"Send File…\" instead.", "BlueDeskリレーは実行中ですが、ファイルを渡せませんでした。\nトレイアイコンを右クリックして「ファイル送信…」を使用してください。", "BlueDesk 릴레이가 실행 중이지만 파일을 전달하지 못했습니다.\n트레이 아이콘을 우클릭하여 \"파일 전송…\"을 사용하세요.");
    public static string AlreadyRunning => Get("BlueDesk 互传助手已在运行（请查看任务栏右下角托盘图标）。", "BlueDesk Relay is already running (check the system tray icon).", "BlueDeskリレーは実行中です（システムトレイアイコンを確認してください）。", "BlueDesk 릴레이가 실행 중입니다 (시스템 트레이 아이콘 확인).");

    // Transfer limit
    public static string TransferLimitFormat => Get("传输上限：{0}（由手机设置）", "Transfer limit: {0} (set by phone)", "転送上限：{0}（スマホで設定）", "전송 한도: {0} (폰에서 설정)");
    public static string Unlimited => Get("不限", "Unlimited", "無制限", "무제한");
    public static string DefaultFolderName => Get("文件夹", "Folder", "フォルダ", "폴더");

    // ---- 辅助方法 ----

    /// <summary>按当前语言从四选一返回</summary>
    private static string Get(string zh, string en, string ja, string ko) => Active switch
    {
        Lang.Zh => zh,
        Lang.Ja => ja,
        Lang.Ko => ko,
        _ => en,
    };

    /// <summary>带格式化参数的 Get</summary>
    public static string Format(string template, params object[] args) =>
        string.Format(template, args);

    /// <summary>传输上限文案（0 = 不限；整 MB 不带小数）</summary>
    public static string FormatLimit(long maxBytes)
    {
        if (maxBytes <= 0) return Unlimited;
        if (maxBytes % (1024 * 1024) == 0) return $"{maxBytes / (1024 * 1024)} MB";
        return FormatSize(maxBytes);
    }

    public static string FormatSize(long bytes) => bytes switch
    {
        >= 1024 * 1024 => $"{bytes / 1024f / 1024f:F1} MB",
        >= 1024 => $"{bytes / 1024f:F1} KB",
        _ => $"{bytes} B",
    };

    /// <summary>菜单里那行只读文案</summary>
    public static string MaxBytesText(long maxBytes) =>
        Format(TransferLimitFormat, FormatLimit(maxBytes));
}
