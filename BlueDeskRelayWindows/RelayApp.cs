using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace BlueDeskRelay;

/// <summary>
/// 托盘主程序：热键 Ctrl+Alt+B 发送剪贴板，托盘菜单发送文件 / 查看状态 / 退出。
/// 手机端收到后可在「互传」页一键转发给另一台电脑。
///
/// 另外注册了资源管理器右键菜单「发送到 BlueDesk」：选中文件 → 右键 → 直接交给手机。
///
/// 注意：.NET 5+ 的 WinForms 已移除 .NET Framework 时代的 <c>MenuItem</c> / <c>ContextMenu</c>，
/// 必须使用 <see cref="ToolStripMenuItem"/> / <see cref="ContextMenuStrip"/>。
/// </summary>
public sealed class RelayApp : Form
{
    private const int HotkeyId = 0xBDEC;
    private const int HotkeyFileId = 0xBDED;
    private const uint WmHotkey = 0x0312;
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const uint VkB = 0x42;
    private const uint VkF = 0x46;

    private readonly PhoneLink _link = new();
    private readonly PhoneLink _dataLink = new(PhoneLinkRole.Data);
    private readonly NotifyIcon _tray;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _connectItem;
    private readonly ToolStripMenuItem _sendClipItem;
    private readonly ToolStripMenuItem _sendFileItem;
    private readonly ToolStripMenuItem _sendFolderItem;
    private readonly ToolStripMenuItem _sendSelectedItem;
    private readonly ToolStripMenuItem _maxBytesItem;
    private readonly CancellationTokenSource _lifeCts = new();
    private bool _quitting;

    /// <summary>文件发送串行化：右键多次调用 / 托盘菜单并发时，帧不能交叉</summary>
    private readonly SemaphoreSlim _fileSendGate = new(1, 1);

    /// <summary>右键菜单带来的文件：手机还没连上时先排队，连上后自动发</summary>
    private readonly List<string> _pendingShellFiles = new();

    private bool _ipcStarted;

    /// <summary>已配对设备缓存（WinRT 枚举，毫秒级；用于「连接设备」子菜单）</summary>
    private IReadOnlyList<PairedDevice> _paired = Array.Empty<PairedDevice>();
    private DateTime _pairedAt = DateTime.MinValue;
    private bool _pairedLoading;

    public RelayApp(IReadOnlyList<string>? initialFiles = null)
    {
        // 控制链路持有数据链路：发送文件/文件夹时优先走 TCP
        _link.DataLink = _dataLink;

        // 隐藏主窗体（仅作为消息宿主）
        ShowInTaskbar = false;
        WindowState = FormWindowState.Minimized;
        FormBorderStyle = FormBorderStyle.None;
        Opacity = 0;
        Text = Strings.AppTitle;

        _statusItem = new ToolStripMenuItem(Strings.NotConnected) { Enabled = false };
        _connectItem = new ToolStripMenuItem(Strings.ConnectDevice);
        _connectItem.DropDownOpening += (_, _) => RebuildConnectMenu();
        _sendClipItem = new ToolStripMenuItem(Strings.SendClipboard, null,
            async (_, _) => await SendClipboardAsync()) { Enabled = false };
        _sendFileItem = new ToolStripMenuItem(Strings.SendFile, null,
            async (_, _) => await SendFileAsync()) { Enabled = false };
        _sendFolderItem = new ToolStripMenuItem(Strings.SendFolder, null,
            async (_, _) => await SendFolderAsync()) { Enabled = false };
        _sendSelectedItem = new ToolStripMenuItem(Strings.SendSelected, null,
            async (_, _) => await SendSelectedFromExplorerAsync()) { Enabled = false };
        _maxBytesItem = new ToolStripMenuItem(Strings.MaxBytesText(RelaySettings.LoadMaxBytes()))
        {
            Enabled = false,
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_connectItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_sendClipItem);
        menu.Items.Add(_sendFileItem);
        menu.Items.Add(_sendFolderItem);
        menu.Items.Add(_sendSelectedItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_maxBytesItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(Strings.Quit, null, (_, _) => Quit()));

        _tray = new NotifyIcon
        {
            // 托盘也使用应用图标，保持和任务栏 / 资源管理器一致
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
            Text = Strings.AppTitle,
            ContextMenuStrip = menu,
            Visible = true,
        };
        _tray.DoubleClick += async (_, _) => await SendClipboardAsync();

        _link.ConnectionChanged += (connected, name) => Post(() =>
        {
            // 蓝牙控制链路断开时，数据链路也一并关闭（重连后手机会重新下发端点）
            if (!connected) _dataLink.Disconnect();

            RelayLog.Write(connected ? Strings.Format(Strings.ConnectedFormat, name) : Strings.Format(Strings.DisconnectedFormat, name));
            // 连接后把当前通道也标出来：蓝牙还是 Wi-Fi，一眼能看出有没有走快通道
            var transport = _link.TransportDescription;
            _statusItem.Text = connected
                ? (string.IsNullOrEmpty(transport)
                    ? Strings.Format(Strings.ConnectedFormat, name)
                    : Strings.Format(Strings.TransportFormat, name, transport))
                : Strings.NotConnectedReconnecting;
            _sendClipItem.Enabled = connected;
            _sendFileItem.Enabled = connected;
            _sendFolderItem.Enabled = connected;
            _sendSelectedItem.Enabled = connected;
            _tray.Text = connected ? Strings.Format(Strings.TrayConnectedFormat, name) : Strings.AppTitle;
            _tray.ShowBalloonTip(1500, Strings.AppTitle,
                connected ? Strings.Format(Strings.ConnectedFormat, name) : Strings.PhoneDisconnectedReconnecting, ToolTipIcon.Info);

            // 右键菜单送来的文件可能在连接建立前就排队了，这里补发
            if (connected && _pendingShellFiles.Count > 0)
            {
                var pending = _pendingShellFiles.ToList();
                _pendingShellFiles.Clear();
                _ = SendFilesFromShellAsync(pending);
            }
        });

        _link.TextReceived += text => Post(() =>
        {
            if (TrySetClipboard(text))
            {
                RelayLog.Write($"收到文本 {text.Length} 字，已写入剪贴板");
                _tray.ShowBalloonTip(2000, Strings.TextReceivedTitle,
                    Strings.Format(Strings.TextReceivedBodyFormat, text.Length), ToolTipIcon.Info);
            }
            else
            {
                RelayLog.Write($"收到文本 {text.Length} 字，但写剪贴板失败");
                _tray.ShowBalloonTip(2000, Strings.ClipboardWriteFailed,
                    Strings.ClipboardBusy, ToolTipIcon.Error);
            }
        });

        // 文件/文件夹可能从蓝牙控制链路或 TCP 数据链路到达，两个实例共用同一套 UI 反馈
        _link.FileReceived += OnFileReceived;
        _dataLink.FileReceived += OnFileReceived;

        // 手机下发传输上限：仅刷新菜单文案（0 显示「不限」）
        _link.MaxBytesChanged += OnMaxBytesChanged;
        _dataLink.MaxBytesChanged += OnMaxBytesChanged;

        // 文件夹批次收完只弹一次气泡；单个文件不再逐个提示
        _link.FolderReceived += OnFolderReceived;
        _dataLink.FolderReceived += OnFolderReceived;

        // NET_INFO 到达后立刻唤醒数据链路，不用干等重试间隔
        _link.NetworkEndpointUpdated += () => _dataLink.RequestConnectNow();

        // 全局热键 Ctrl+Alt+B（剪贴板）；Ctrl+Alt+F（发送资源管理器里选中的文件）
        if (!RegisterHotKey(Handle, HotkeyId, ModControl | ModAlt, VkB))
        {
            _tray.ShowBalloonTip(3000, Strings.HotkeyFailed,
                Strings.HotkeyBOccupied, ToolTipIcon.Warning);
        }
        if (!RegisterHotKey(Handle, HotkeyFileId, ModControl | ModAlt, VkF))
        {
            _tray.ShowBalloonTip(3000, Strings.HotkeyFailed,
                Strings.HotkeyFOccupied, ToolTipIcon.Warning);
        }

        // 自动连接 + 断线重连（常驻后台，直到退出）
        _ = Task.Run(() => _link.SuperviseAsync(_lifeCts.Token));

        // 数据链路守护：只在蓝牙控制链路在线时连接（端点由手机 NET_INFO 下发）
        _ = Task.Run(() => _dataLink.SuperviseDataAsync(
            () => _link.IsConnected && !_link.IsWifi, _lifeCts.Token));

        // 预取已配对设备，保证「连接设备」菜单展开即有内容
        _ = RefreshPairedAsync();

        // 注册资源管理器右键菜单（HKCU，无需管理员权限）
        ExplorerMenu.Install();

        // 从右键菜单直接启动时，文件先排队，连上手机后自动发送
        if (initialFiles is { Count: > 0 })
        {
            _pendingShellFiles.AddRange(initialFiles);
            _tray.ShowBalloonTip(2000, Strings.AppTitle,
                Strings.Format(Strings.ConnectingWillSendFormat, initialFiles.Count), ToolTipIcon.Info);
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (_ipcStarted) return;
        _ipcStarted = true;
        // 已有一个实例在跑时，右键菜单的新实例会把文件路径通过命名管道送进来
        ShellSendIpc.StartServer(paths => Post(() => _ = SendFilesFromShellAsync(paths)));
    }

    // ------------------------------------------------------------
    // 连接设备（对应 Mac 端「连接设备 ▸」子菜单）
    // ------------------------------------------------------------

    /// <summary>子菜单每次展开时重建：列出全部已配对设备，打勾当前连接、★ 标注记忆设备</summary>
    private void RebuildConnectMenu()
    {
        var drop = _connectItem.DropDownItems;
        drop.Clear();

        if (_paired.Count == 0)
        {
            var hint = new ToolStripMenuItem(
                _pairedLoading ? Strings.ReadingPaired : Strings.NoPairedDevices)
            {
                Enabled = false,
            };
            drop.Add(hint);
        }
        else
        {
            var connected = _link.ConnectedAddress;
            var preferred = RelaySettings.LoadPhoneAddress();

            foreach (var device in _paired)
            {
                var isConnected = string.Equals(device.Address, connected, StringComparison.OrdinalIgnoreCase);
                var isPreferred = string.Equals(device.Address, preferred, StringComparison.OrdinalIgnoreCase);
                // 打勾留给「正在连接」，记忆设备用 ★ 标注（与 Mac 端一致）
                var text = !_link.IsConnected && isPreferred ? Strings.Format(Strings.PreferredMark, device.Name) : device.Name;

                var item = new ToolStripMenuItem(text) { Checked = isConnected };
                item.Click += (_, _) => OnPickDevice(device);
                drop.Add(item);
            }

            drop.Add(new ToolStripSeparator());
        }

        drop.Add(new ToolStripMenuItem(Strings.RefreshDevices, null,
            async (_, _) => { await RefreshPairedAsync(); }));
        drop.Add(new ToolStripMenuItem(Strings.ClearPreferred, null,
            (_, _) => ClearPreferred()));

        // 缓存过期就在后台刷新，下次展开即为最新（不阻塞本次展开）
        if (!_pairedLoading && DateTime.UtcNow - _pairedAt > TimeSpan.FromSeconds(60))
            _ = RefreshPairedAsync();
    }

    private async Task RefreshPairedAsync()
    {
        if (_pairedLoading) return;
        _pairedLoading = true;
        try
        {
            _paired = await PairedDevices.ListAsync(_lifeCts.Token);
            _pairedAt = DateTime.UtcNow;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[RelayApp] 刷新设备列表失败：{ex.Message}");
        }
        finally
        {
            _pairedLoading = false;
        }
    }

    /// <summary>点选设备：断开当前连接，改连这一台，并记住它</summary>
    private void OnPickDevice(PairedDevice device)
    {
        _link.RequestConnect(device.Address, device.Name);
        _tray.ShowBalloonTip(1500, Strings.Connecting, Strings.Format(Strings.ConnectingFormat, device.Name), ToolTipIcon.Info);
    }

    private void ClearPreferred()
    {
        _link.ClearPreferred();
        _tray.ShowBalloonTip(1500, Strings.PreferredCleared,
            Strings.PreferredClearedBody, ToolTipIcon.Info);
    }

    /// <summary>从后台线程安全地投递到 UI 线程</summary>
    private void Post(Action action)
    {
        try
        {
            if (IsHandleCreated && !IsDisposed) BeginInvoke(action);
        }
        catch (ObjectDisposedException) { }
        catch (InvalidOperationException) { }
    }

    private void OnFileReceived(string path, long size) => Post(() =>
    {
        RelayLog.Write($"收到文件 {path}（{Strings.FormatSize(size)}）");
        _tray.ShowBalloonTip(3000, Strings.FileReceivedTitle,
            Strings.Format(Strings.FileReceivedBodyFormat, Path.GetFileName(path), Strings.FormatSize(size), Path.GetDirectoryName(path) ?? PhoneLink.GetReceiveDir()),
            ToolTipIcon.Info);
    });

    private void OnFolderReceived(string folder, int files) => Post(() =>
    {
        _tray.ShowBalloonTip(3000, Strings.FolderReceivedTitle,
            Strings.Format(Strings.FolderReceivedBodyFormat, folder, files), ToolTipIcon.Info);
    });

    private void OnMaxBytesChanged(long max) => Post(() =>
    {
        _maxBytesItem.Text = Strings.MaxBytesText(max);
    });

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WmHotkey)
        {
            var id = m.WParam.ToInt32();
            if (id == HotkeyId)
            {
                _ = SendClipboardAsync();
                return;
            }
            if (id == HotkeyFileId)
            {
                _ = SendSelectedFromExplorerAsync();
                return;
            }
        }
        base.WndProc(ref m);
    }

    private async Task SendClipboardAsync()
    {
        try
        {
            if (!_link.IsConnected)
            {
                _tray.ShowBalloonTip(1500, Strings.NotConnected, Strings.NotConnectedTryAgain, ToolTipIcon.Warning);
                return;
            }
            var text = GetClipboardText();
            if (string.IsNullOrEmpty(text))
            {
                _tray.ShowBalloonTip(1500, Strings.ClipboardEmpty, Strings.ClipboardEmptyHint, ToolTipIcon.Warning);
                return;
            }
            await _link.SendTextAsync(text);
            _tray.ShowBalloonTip(1500, Strings.SentTitle, Strings.Format(Strings.SentBodyFormat, text.Length), ToolTipIcon.Info);
        }
        catch (Exception ex)
        {
            _tray.ShowBalloonTip(2000, Strings.SendFailed, ex.Message, ToolTipIcon.Error);
        }
    }

    private async Task SendFileAsync()
    {
        try
        {
            using var dialog = new OpenFileDialog { Title = Strings.SelectFile, Multiselect = false };
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            if (!_link.IsConnected)
            {
                _tray.ShowBalloonTip(1500, Strings.NotConnected, Strings.NotConnectedTryAgain, ToolTipIcon.Warning);
                return;
            }
            var info = new FileInfo(dialog.FileName);
            if (!WithinLimit(info.Length, out var limitText))
            {
                _tray.ShowBalloonTip(2000, Strings.FileTooLarge,
                    Strings.Format(Strings.FileTooLargeFormat, info.Name, limitText), ToolTipIcon.Warning);
                return;
            }
            _tray.ShowBalloonTip(1500, Strings.SendingTitle, Strings.Format(Strings.SendingBodyFormat, info.Name, Strings.FormatSize(info.Length)), ToolTipIcon.Info);
            await _fileSendGate.WaitAsync();
            try { await _link.SendFileAsync(dialog.FileName); }
            finally { _fileSendGate.Release(); }
        }
        catch (Exception ex)
        {
            _tray.ShowBalloonTip(2000, Strings.SendFailed, ex.Message, ToolTipIcon.Error);
        }
    }

    /// <summary>托盘菜单「发送文件夹…」：文件夹整批经由 BATCH_META/FILE_*/BATCH_END 发送</summary>
    private async Task SendFolderAsync()
    {
        try
        {
            using var dialog = new FolderBrowserDialog
            {
                Description = Strings.SelectFolder,
                UseDescriptionForTitle = true,
            };
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            if (!_link.IsConnected)
            {
                _tray.ShowBalloonTip(1500, Strings.NotConnected, Strings.NotConnectedTryAgain, ToolTipIcon.Warning);
                return;
            }

            _tray.ShowBalloonTip(2000, Strings.SendingTitle, Strings.SendingFolderStats, ToolTipIcon.Info);
            await _fileSendGate.WaitAsync();
            try
            {
                var result = await _link.SendFolderAsync(dialog.SelectedPath);
                var skipped = result.Skipped > 0 ? Strings.Format(Strings.SkippedFormat, result.Skipped) : "";
                _tray.ShowBalloonTip(3000, Strings.FolderSentTitle,
                    Strings.Format(Strings.FolderSentBodyFormat, result.FolderName, result.FileCount, Strings.FormatSize(result.Bytes), skipped),
                    result.Skipped > 0 ? ToolTipIcon.Warning : ToolTipIcon.Info);
            }
            finally { _fileSendGate.Release(); }
        }
        catch (Exception ex)
        {
            _tray.ShowBalloonTip(3000, Strings.SendFolderFailed, ex.Message, ToolTipIcon.Error);
        }
    }

    /// <summary>
    /// 资源管理器右键「发送到 BlueDesk」送来的文件。
    /// 与托盘菜单共用一把发送锁，多个文件顺序发送，避免分块帧交叉。
    /// </summary>
    private async Task SendFilesFromShellAsync(IReadOnlyList<string> paths)
    {
        // 手机没连上时先排队，等 ConnectionChanged 连上后再补发
        if (!_link.IsConnected)
        {
            var queued = paths.Where(File.Exists).ToList();
            if (queued.Count == 0) return;
            _pendingShellFiles.AddRange(queued);
            _tray.ShowBalloonTip(2000, Strings.WaitingConnection,
                Strings.Format(Strings.WaitingConnectionFormat, queued.Count), ToolTipIcon.Info);
            return;
        }

        foreach (var raw in paths)
        {
            try
            {
                var path = raw.Trim();
                if (path.Length == 0 || !File.Exists(path)) continue;

                if (!_link.IsConnected)
                {
                    _tray.ShowBalloonTip(1500, Strings.NotConnected,
                        Strings.NotConnectedYet, ToolTipIcon.Warning);
                    continue;
                }

                var info = new FileInfo(path);
                if (!WithinLimit(info.Length, out var limitText))
                {
                    _tray.ShowBalloonTip(2000, Strings.FileTooLarge,
                        Strings.Format(Strings.FileTooLargeFormat, info.Name, limitText), ToolTipIcon.Warning);
                    continue;
                }

                _tray.ShowBalloonTip(1500, Strings.SendingTitle,
                    Strings.Format(Strings.SendingBodyFormat, info.Name, Strings.FormatSize(info.Length)), ToolTipIcon.Info);
                await _fileSendGate.WaitAsync();
                try { await _link.SendFileAsync(path); }
                finally { _fileSendGate.Release(); }
                _tray.ShowBalloonTip(2000, Strings.SentTitle,
                    Strings.Format(Strings.FileSentBodyFormat, info.Name), ToolTipIcon.Info);
            }
            catch (Exception ex)
            {
                _tray.ShowBalloonTip(2000, Strings.SendFailed, ex.Message, ToolTipIcon.Error);
            }
        }
    }

    /// <summary>
    /// 全局热键 Ctrl+Alt+F：把资源管理器当前选中的文件发给手机。
    /// 前台不是资源管理器时，退回到剪贴板里 Ctrl+C 复制的文件。
    /// </summary>
    private async Task SendSelectedFromExplorerAsync()
    {
        var files = GetExplorerSelection();
        if (files.Count == 0) files = GetClipboardFiles();

        if (files.Count == 0)
        {
            _tray.ShowBalloonTip(2500, Strings.NoFileSelected,
                Strings.NoFileSelectedHint,
                ToolTipIcon.Warning);
            return;
        }

        RelayLog.Write($"快捷键发送 {files.Count} 个文件");
        await SendFilesFromShellAsync(files);
    }

    /// <summary>
    /// 读资源管理器前台窗口的选中项（不需要用户先 Ctrl+C）。
    /// 走 Shell.Application 的 COM 晚绑定，任何一步失败都退回空列表。
    /// </summary>
    private static List<string> GetExplorerSelection()
    {
        var files = new List<string>();
        try
        {
            var foreground = GetForegroundWindow();
            if (foreground == IntPtr.Zero) return files;

            var shellType = Type.GetTypeFromProgID("Shell.Application");
            if (shellType is null) return files;

            dynamic shell = Activator.CreateInstance(shellType)!;
            dynamic windows = shell.Windows();
            int windowCount = Convert.ToInt32(windows.Count);

            for (int i = 0; i < windowCount; i++)
            {
                try
                {
                    dynamic window = windows.Item(i);
                    if (Convert.ToInt64(window.HWND) != foreground.ToInt64()) continue;

                    dynamic items = window.Document.SelectedItems();
                    int itemCount = Convert.ToInt32(items.Count);
                    for (int j = 0; j < itemCount; j++)
                    {
                        dynamic item = items.Item(j);
                        var path = Convert.ToString(item.Path);
                        if (!string.IsNullOrEmpty(path) && File.Exists(path)) files.Add(path);
                    }
                }
                catch
                {
                    // 单个窗口读取失败不影响其他窗口
                }
            }
        }
        catch (Exception ex)
        {
            RelayLog.Write($"读取资源管理器选中项失败：{ex.Message}");
        }
        return files;
    }

    /// <summary>剪贴板里 Ctrl+C 复制的文件（CF_HDROP）</summary>
    private static List<string> GetClipboardFiles()
    {
        for (int i = 0; i < 5; i++)
        {
            try
            {
                var files = new List<string>();
                if (!Clipboard.ContainsFileDropList()) return files;
                foreach (var path in Clipboard.GetFileDropList())
                {
                    if (!string.IsNullOrEmpty(path) && File.Exists(path)) files.Add(path);
                }
                return files;
            }
            catch (ExternalException)
            {
                Thread.Sleep(60); // 剪贴板被别的程序占用，重试
            }
        }
        return new List<string>();
    }

    private void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        try { _lifeCts.Cancel(); } catch { }
        _link.Dispose();
        _dataLink.Dispose();
        _tray.Visible = false;
        _tray.Dispose();
        Application.Exit();
    }

    protected override void SetVisibleCore(bool value) => base.SetVisibleCore(false);

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        if (!_quitting)
        {
            _quitting = true;
            try { _lifeCts.Cancel(); } catch { }
            _link.Dispose();
            _dataLink.Dispose();
            _tray.Visible = false;
            _tray.Dispose();
        }
        UnregisterHotKey(Handle, HotkeyId);
        UnregisterHotKey(Handle, HotkeyFileId);
        base.OnFormClosed(e);
    }

    /// <summary>剪贴板可能被其他程序短暂占用，重试几次</summary>
    private static string GetClipboardText()
    {
        for (int i = 0; i < 5; i++)
        {
            try { return Clipboard.GetText(); }
            catch (ExternalException) { Thread.Sleep(60); }
        }
        return "";
    }

    private static bool TrySetClipboard(string text)
    {
        for (int i = 0; i < 5; i++)
        {
            try { Clipboard.SetText(text); return true; }
            catch (ExternalException) { Thread.Sleep(60); }
        }
        return false;
    }

    /// <summary>按手机下发的上限校验（0 不限）；超限时给出文案</summary>
    private static bool WithinLimit(long size, out string limitText)
    {
        var max = RelaySettings.LoadMaxBytes();
        limitText = Strings.FormatLimit(max);
        return max <= 0 || size <= max;
    }

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(nint hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(nint hWnd, int id);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
}

/// <summary>
/// 资源管理器右键菜单：HKCU\Software\Classes\*\shell\BlueDeskSend
/// 只写当前用户，不需要管理员权限；程序每次启动都刷新一次，保证路径最新。
/// </summary>
internal static class ExplorerMenu
{
    private const string KeyPath = @"Software\Classes\*\shell\BlueDeskSend";
    private static readonly string DisplayName = Strings.SendToBlueDesk;

    public static void Install()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe)) return;

            using var shell = Registry.CurrentUser.CreateSubKey(KeyPath, writable: true);
            if (shell is null) return;
            shell.SetValue(null, DisplayName);
            shell.SetValue("Icon", exe);
            // Document：多选时资源管理器逐个调用；本程序用命名管道把它们并到已运行实例
            shell.SetValue("MultiSelectModel", "Document");

            using var command = shell.CreateSubKey("command", writable: true);
            command?.SetValue(null, $"\"{exe}\" --send-file \"%1\"");

            RelayLog.Write($"已注册资源管理器右键菜单：{exe}");
        }
        catch (Exception ex)
        {
            RelayLog.Write($"注册右键菜单失败：{ex.Message}");
        }
    }
}

/// <summary>
/// 右键菜单与已运行实例之间的单文件交接：命名管道，
/// 避免第二个进程和第一实例抢蓝牙连接。
/// </summary>
internal static class ShellSendIpc
{
    private const string PipeName = "BlueDeskRelay.SendFile";

    /// <summary>第一个实例：常驻监听右键送来的文件路径</summary>
    public static void StartServer(Action<string[]> onFiles)
    {
        Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    using var server = new NamedPipeServerStream(
                        PipeName, PipeDirection.In, 1,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                    await server.WaitForConnectionAsync();

                    using var reader = new StreamReader(server, Encoding.UTF8);
                    var files = new List<string>();
                    while (await reader.ReadLineAsync() is { } line)
                    {
                        line = line.Trim();
                        if (line.Length > 0) files.Add(line);
                    }
                    if (files.Count > 0) onFiles(files.ToArray());
                }
                catch (Exception ex)
                {
                    RelayLog.Write($"右键发送通道异常：{ex.Message}");
                    await Task.Delay(200);
                }
            }
        });
    }

    /// <summary>第二个实例：把文件路径交给已运行实例，返回是否送达</summary>
    public static bool TrySendToRunning(IReadOnlyList<string> files)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            client.Connect(3000);
            using var writer = new StreamWriter(client, new UTF8Encoding(false)) { AutoFlush = true };
            foreach (var file in files) writer.WriteLine(file);
            return true;
        }
        catch (Exception ex)
        {
            RelayLog.Write($"交付右键文件失败：{ex.Message}");
            return false;
        }
    }
}

internal static class Program
{
    private const string MutexName = @"Global\BlueDeskRelay.SingleInstance";

    [STAThread]
    private static void Main(string[] args)
    {
        var shellFiles = ParseShellFiles(args);

        // 单实例：两个实例会争抢同一个全局热键，第二个注册必然失败
        using var mutex = new Mutex(true, MutexName, out bool isFirst);
        if (!isFirst)
        {
            if (shellFiles.Count > 0)
            {
                // 资源管理器右键：交给已在运行的实例发送，本进程直接退出
                if (ShellSendIpc.TrySendToRunning(shellFiles)) return;
                MessageBox.Show(
                    Strings.AlreadyRunningTransferFailed,
                    Strings.AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            MessageBox.Show(Strings.AlreadyRunning,
                Strings.AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new RelayApp(shellFiles));
    }

    /// <summary>解析资源管理器传入的 --send-file "路径"（可能多次）</summary>
    private static List<string> ParseShellFiles(string[] args)
    {
        var files = new List<string>();
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (string.Equals(args[i], "--send-file", StringComparison.OrdinalIgnoreCase))
                files.Add(args[++i]);
        }
        return files;
    }
}
