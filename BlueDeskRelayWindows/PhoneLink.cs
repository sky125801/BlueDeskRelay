using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using InTheHand.Net;
using InTheHand.Net.Bluetooth;
using InTheHand.Net.Sockets;

namespace BlueDeskRelay;

/// <summary>
/// 链路角色。
///
/// Control = 蓝牙控制链路（HELLO/IDENT/CONFIG/NET_INFO/TEXT/PING 等控制与文本帧都走它）；
/// Data = 手机监听端口上的独立 TCP 批量数据链路，只收文件/文件夹帧。
/// 端点一律由手机通过 NET_INFO 自动下发，用户不需要（也不允许）手工配置。
/// </summary>
public enum PhoneLinkRole
{
    Control,
    Data,

    /// <summary>实时键鼠输入车道：独立 TCP 连接，避免被文件块队头阻塞</summary>
    Input,
}

/// <summary>
/// 与手机的蓝牙 SPP 数据通道。
///
/// 连接模型：
///   1. 优先用上次成功连接的地址直连（省掉一次 10~20 秒的蓝牙查询）；
///   2. 失败则发现名为 BlueDesk* 的手机（须已与手机配对）；
///   3. 连接手机的自定义 RFCOMM 服务（Protocol.ServiceUuid）；
///   4. 先发 HELLO（本机名），随后进入读循环：
///      收 TEXT → 写剪贴板；收 FILE_META/CHUNK/END → 存 Downloads\BlueDesk；
///      收到 needAck 的帧 → 回 ACK；收 PING → 回 PONG。
///
/// 双通道模式下，蓝牙控制链路常驻；手机通过 NET_INFO 下发端点后，
/// 另起一个 <see cref="PhoneLinkRole.Data"/> 实例走 TCP 传批量文件。
///
/// 由 <see cref="SuperviseAsync"/>（控制）与 <see cref="SuperviseDataAsync"/>（数据）常驻守护。
/// </summary>
public sealed class PhoneLink : IDisposable
{
    /// <summary>上次回 INPUT_STATE 的时间（毫秒级节流，避免每批都回包）</summary>
    private long _lastInputStateAt;

    /// <summary>输入车道心跳；手机靠它判断链路是否还活着（空闲 1.5s 就会回落 HID）</summary>
    private CancellationTokenSource? _inputHeartbeat;

    /// <summary>最近一批实时输入的序号，心跳里原样带回</summary>
    private long _lastAppliedSeq;

    /// <summary>直连缓存地址的超时（秒）——地址失效时要快速失败，好回退到设备发现</summary>
    private const int CachedConnectTimeoutSeconds = 6;

    /// <summary>设备发现后正式连接的超时（秒）</summary>
    private const int DiscoveredConnectTimeoutSeconds = 20;

    /// <summary>重连间隔</summary>
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(5);

    /// <summary>数据链路连接超时（秒）</summary>
    private const int DataConnectTimeoutSeconds = 4;

    /// <summary>数据链路重连间隔（5~10 秒）</summary>
    private static readonly TimeSpan DataRetryDelay = TimeSpan.FromSeconds(7);

    private readonly PhoneLinkRole _role;
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    /// <summary>发送串行门：保证一个文件/一个文件夹批次的帧序列不与文本或其他文件交错</summary>
    private readonly SemaphoreSlim _sequenceLock = new(1, 1);
    private readonly SemaphoreSlim _wake = new(0, 1);
    private readonly object _gate = new();

    private IRelayTransport? _transport;
    private CancellationTokenSource? _readCts;
    private volatile bool _disposed;


    /// <summary>当前分块大小：蓝牙 4 KB，Wi-Fi 默认 64 KB</summary>
    private int _chunkSize = Protocol.MaxChunk;

    /// <summary>手机是否下发过可用的 TCP 数据通道端点</summary>
    private volatile bool _hasWifiEndpoint;

    /// <summary>等待数据链路超时后的冷却截止时间（UTC），避免每个文件都白等</summary>
    private DateTime _noDataLinkUntil = DateTime.MinValue;

    /// <summary>当前正在接收的文件夹批次（非批次平铺接收时为 null）</summary>
    private BatchReceiver? _batch;
    /// <summary>当前文件在批次内的相对路径（正斜杠）</summary>
    private string? _pendingRelativePath;
    /// <summary>批次已超限/已丢弃：后续文件帧只消费不落盘</summary>
    private bool _ignoreCurrentFile;

    /// <summary>用户从「连接设备」菜单点选的目标地址（下一轮连接优先用它）</summary>
    private string? _pendingTarget;

    public bool IsConnected { get; private set; }
    public string PhoneName { get; private set; } = "";

    /// <summary>当前通道是否走 Wi-Fi</summary>
    public bool IsWifi { get; private set; }

    /// <summary>当前通道描述（菜单与托盘显示用）</summary>
    public string TransportDescription { get; private set; } = "";

    /// <summary>当前连接设备的蓝牙地址（走 Wi-Fi 时为 null；菜单打勾用）</summary>
    public string? ConnectedAddress { get; private set; }

    /// <summary>收到文本（在后台线程回调，调用方需自行切到 UI 线程）</summary>
    public event Action<string>? TextReceived;

    /// <summary>收到手机通知镜像（参数：应用名 / 标题 / 正文，后台线程回调）</summary>
    public event Action<string, string, string>? NotificationReceived;

    /// <summary>收到手机同步来的剪贴板文本（后台线程回调，调用方需自行切到 UI 线程）</summary>
    public event Action<string>? ClipboardReceived;

    /// <summary>收到文件（已完整落盘）</summary>
    public event Action<string, long>? FileReceived;

    /// <summary>手机下发传输上限（在后台线程回调，0 = 不限）</summary>
    public event Action<long>? MaxBytesChanged;

    /// <summary>整个文件夹批次接收完成（参数：文件夹名 / 实际文件数）</summary>
    public event Action<string, int>? FolderReceived;

    /// <summary>连接状态变化</summary>
    public event Action<bool, string>? ConnectionChanged;

    /// <summary>
    /// 控制链路意外断开（手机离开范围 / 蓝牙掉线）。
    /// 主动断开、切换通道、退出程序都不会触发。
    /// </summary>
    public event Action? ControlLinkLost;

    /// <summary>手机下发的设备策略：断开后是否锁屏（默认开启，缓存到本地）</summary>
    public bool LockOnDisconnect { get; private set; } = RelaySettings.LoadLockOnDisconnect();

    /// <summary>收到 NET_INFO 并记住了新的 TCP 数据通道端点（控制链路用于唤醒数据链路）</summary>
    public event Action? NetworkEndpointUpdated;

    /// <summary>控制链路持有的 TCP 数据链路：文件和文件夹优先走它</summary>
    internal PhoneLink? DataLink { get; set; }

    public PhoneLink(PhoneLinkRole role = PhoneLinkRole.Control)
    {
        _role = role;
    }

    /// <summary>立即唤醒守护循环（例如刚拿到新的 NET_INFO 端点）</summary>
    public void RequestConnectNow() => Wake();

    /// <summary>
    /// 数据链路守护：蓝牙控制链路在线时尝试建立 TCP 数据链路，
    /// 连上后断开自动重连；控制链路离线则关闭数据链路并空转等待。
    /// </summary>
    public async Task SuperviseDataAsync(Func<bool> controlOnline, CancellationToken ct = default)
    {
        while (!ct.IsCancellationRequested && !_disposed)
        {
            if (!controlOnline())
            {
                // 没有控制链路时连数据链路没有意义，也会被手机拒绝
                if (IsConnected) DisconnectCore(notify: false);
                try { await DelayOrWake(TimeSpan.FromSeconds(1), ct); }
                catch (OperationCanceledException) { return; }
                continue;
            }

            if (IsConnected)
            {
                try { await DelayOrWake(TimeSpan.FromSeconds(1), ct); }
                catch (OperationCanceledException) { return; }
                continue;
            }

            bool ok;
            try
            {
                ok = await ConnectDataAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[PhoneLink] 数据链路连接异常：{ex.Message}");
                ok = false;
            }

            if (!ok && !ct.IsCancellationRequested)
            {
                try { await DelayOrWake(DataRetryDelay, ct); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    /// <summary>
    /// 常驻守护：保持连接，断开后每 5 秒重试一次，直到 <paramref name="ct"/> 取消。
    /// 原实现只在「首次连上」前循环，连上之后一旦掉线就再也不会重连。
    /// </summary>
    public async Task SuperviseAsync(CancellationToken ct = default)
    {
        while (!ct.IsCancellationRequested && !_disposed)
        {
            if (IsConnected)
            {
                // 已连接：低频轮询等待断线
                try { await DelayOrWake(TimeSpan.FromSeconds(1), ct); }
                catch (OperationCanceledException) { return; }
                continue;
            }

            try
            {
                await ConnectOnceAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[PhoneLink] 连接失败：{ex.Message}");
            }

            if (!IsConnected)
            {
                try { await DelayOrWake(RetryDelay, ct); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    /// <summary>
    /// 等待指定时长，或提前被 <see cref="RequestConnect"/> 唤醒。
    /// 用于手动选设备后立刻重连，而不用干等 5 秒的重试间隔。
    /// </summary>
    private async Task DelayOrWake(TimeSpan delay, CancellationToken ct)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var wake = _wake.WaitAsync(linked.Token);
        var timer = Task.Delay(delay, linked.Token);
        await Task.WhenAny(wake, timer);
        linked.Cancel();
        // 两个任务都要 await 一次，避免被取消的那个留下未观察的异常
        try { await wake; } catch { }
        try { await timer; } catch { }
        ct.ThrowIfCancellationRequested();
    }

    /// <summary>
    /// 手动连接指定设备（对应 Mac 端菜单「连接设备 ▸」点选）：
    /// 断开当前连接 → 记住该设备 → 立刻唤醒守护循环去连它。
    /// </summary>
    public void RequestConnect(string address, string name)
    {
        lock (_gate) { _pendingTarget = address; }
        RelaySettings.SavePhone(address, name);
        Disconnect();
        Wake();
    }

    /// <summary>清除记忆设备，恢复自动发现 BlueDesk*</summary>
    public void ClearPreferred()
    {
        lock (_gate) { _pendingTarget = null; }
        RelaySettings.Clear();
    }

    private void Wake()
    {
        try { _wake.Release(); } catch (SemaphoreFullException) { }
    }

    private async Task ConnectOnceAsync(CancellationToken ct)
    {
        // 0) 用户刚刚手动点选了设备：本轮只连它，不做发现
        string? pending;
        lock (_gate)
        {
            pending = _pendingTarget;
            _pendingTarget = null;
        }
        if (!string.IsNullOrWhiteSpace(pending) &&
            TryParseAddress(pending, out var picked))
        {
            var pickedName = RelaySettings.LoadPhoneName() ?? pending;
            await TryConnectAsync(picked, pickedName, DiscoveredConnectTimeoutSeconds, ct);
            return;
        }

        // 1) 先试上次成功的蓝牙地址，避免每次都做全量蓝牙查询
        var saved = RelaySettings.LoadPhoneAddress();
        if (!string.IsNullOrWhiteSpace(saved) && TryParseAddress(saved, out var cached))
        {
            var cachedName = RelaySettings.LoadPhoneName() ?? saved;
            if (await TryConnectAsync(cached, cachedName, CachedConnectTimeoutSeconds, ct)) return;
        }

        // 2) 回退：发现已配对的 BlueDesk 手机
        var found = await DiscoverPhoneAsync(ct);
        if (found is null)
        {
            Debug.WriteLine("[PhoneLink] 未找到已配对的 BlueDesk 手机");
            return;
        }

        var target = found.Value;
        await TryConnectAsync(target.Address, target.Name, DiscoveredConnectTimeoutSeconds, ct);
    }

    private static async Task<PhoneTarget?> DiscoverPhoneAsync(CancellationToken ct)
    {
        try
        {
            return await Task.Run(() =>
            {
                using var probe = new BluetoothClient();
                // 只用文档里稳定的单参重载：多参重载 (maxDevices, authenticated, remembered, unknown)
                // 在 4.1.40 / 4.1.44 之间参数名改过，用命名实参会编译失败。
                // 这里改为发现后按 Authenticated（已配对）过滤，语义一致。
                var devices = probe.DiscoverDevices(255);
                var hit = devices.FirstOrDefault(d =>
                    d.Authenticated &&
                    !string.IsNullOrEmpty(d.DeviceName) &&
                    d.DeviceName.StartsWith("BlueDesk", StringComparison.OrdinalIgnoreCase));
                if (hit is null) return (PhoneTarget?)null;
                return new PhoneTarget(hit.DeviceAddress, hit.DeviceName);
            }, ct);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            Debug.WriteLine($"[PhoneLink] 设备发现失败：{ex.Message}");
            return null;
        }
    }

    private async Task<bool> TryConnectAsync(
        BluetoothAddress address, string name, int timeoutSeconds, CancellationToken ct)
    {
        var client = new BluetoothClient();
        try
        {
            var endpoint = new BluetoothEndPoint(address, Protocol.ServiceUuid);
            // Connect 本身是阻塞调用且没有超时参数，用 WaitAsync 兜住，
            // 否则手机不在范围内时会卡住几十秒，重连逻辑就形同虚设。
            await Task.Run(() => client.Connect(endpoint), ct)
                .WaitAsync(TimeSpan.FromSeconds(timeoutSeconds), ct);
        }
        catch (Exception ex)
        {
            client.Dispose();
            Debug.WriteLine($"[PhoneLink] 连接 {address} 失败：{ex.Message}");
            return false;
        }

        Stream stream;
        try
        {
            stream = client.GetStream();
        }
        catch (Exception ex)
        {
            client.Dispose();
            Debug.WriteLine($"[PhoneLink] 取流失败：{ex.Message}");
            return false;
        }

        var ok = await FinishConnectAsync(
            new BluetoothRelayTransport(client, stream), name, address.ToString(), ct);
        if (ok)
        {
            RelaySettings.SavePhone(address.ToString(), name);
        }
        return ok;
    }

    /// <summary>
    /// 建立独立的 TCP 数据链路：连上后先 HELLO，再发带 role=data 的 IDENT，
    /// 手机据此把这条连接挂到同一台 PC 的蓝牙控制会话上（不会断蓝牙）。
    /// </summary>
    private async Task<bool> ConnectDataAsync(CancellationToken ct)
    {
        var endpoint = RelaySettings.LoadWifiEndpoint();
        if (endpoint is null) return false;

        var (host, port) = endpoint.Value;
        var client = new TcpClient();
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(DataConnectTimeoutSeconds));
            await client.ConnectAsync(host, port, timeout.Token);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            client.Dispose();
            throw;
        }
        catch (Exception ex)
        {
            client.Dispose();
            Debug.WriteLine($"[PhoneLink] 数据链路连接 {host}:{port} 失败：{ex.Message}");
            return false;
        }

        try
        {
            client.NoDelay = true;
            client.SendBufferSize = 256 * 1024;
            client.ReceiveBufferSize = 256 * 1024;
        }
        catch { }

        var name = RelaySettings.LoadPhoneName() ?? host;
        var ok = await FinishConnectAsync(new TcpRelayTransport(client), name, null, ct);
        if (ok)
        {
            RelayLog.Write($"数据通道已建立 {host}:{port}");
        }
        return ok;
    }

    /// <summary>
    /// 通道建好之后的统一收尾：登记状态 → 报 HELLO 与 IDENT → 起读循环。
    /// 蓝牙控制链路与数据链路共用这一段，避免两条路径各写一份。
    /// </summary>
    private async Task<bool> FinishConnectAsync(
        IRelayTransport transport, string name, string? btAddress, CancellationToken ct)
    {
        var isData = _role == PhoneLinkRole.Data;
        var isInput = _role == PhoneLinkRole.Input;
        lock (_gate)
        {
            _transport = transport;
            PhoneName = name;
            ConnectedAddress = btAddress;
            IsWifi = transport.IsWifi;
            TransportDescription = transport.Description;
            _chunkSize = transport.IsWifi ? RelaySettings.LoadWifiChunk() : Protocol.MaxChunk;
            IsConnected = true;
        }

        try
        {
            // 报身份（手机端 5 秒内收不到 HELLO 会主动断开）
            await SendAsync(Protocol.Hello(Environment.MachineName), ct);
            // 走 TCP 时手机拿不到蓝牙 MAC，补一个 IDENT 让它把会话认回这台电脑；
            // 数据链路额外带 role=data，手机只把它挂到控制会话上，不会断蓝牙。
            await SendAsync(Protocol.Ident(BuildIdent(transport.IsWifi, isData, isInput)), ct);
            // 数据链路不承担脚本；控制链路上额外宣告「本机可代跑脚本步骤 + 可接收实时输入」，
            // 手机据此把执行方式从 HID 上报切到本地注入，并建立 role=input 的输入车道。
            if (!isData && !isInput)
                await SendAsync(Protocol.AgentInfo(1, "win", true, false, input: 1, text: 1), ct);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[PhoneLink] HELLO 发送失败：{ex.Message}");
            Disconnect();
            return false;
        }

        // 数据链路与输入车道不算「手机连接状态」，状态与托盘只反映蓝牙控制链路
        if (!isData && !isInput) ConnectionChanged?.Invoke(true, name);
        StartReadLoop();
        if (isInput) StartInputHeartbeat();
        return true;
    }

    /// <summary>
    /// 输入车道心跳：每 500ms 回一次 INPUT_STATE。
    ///
    /// 手机侧以「1.5 秒内收到回执」判定 Wi-Fi 可用；若只在收到输入时才回包，
    /// 用户静止 1.5 秒后再操作就会被误判为链路失效而回落 HID。
    /// </summary>
    private void StartInputHeartbeat()
    {
        try { _inputHeartbeat?.Cancel(); } catch { }
        var cts = new CancellationTokenSource();
        _inputHeartbeat = cts;
        _ = Task.Run(async () =>
        {
            try
            {
                while (!cts.IsCancellationRequested && IsConnected)
                {
                    var seq = Interlocked.Read(ref _lastAppliedSeq);
                    await SendAsync(Protocol.InputState(seq, 0, true), cts.Token);
                    await Task.Delay(500, cts.Token);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Debug.WriteLine($"[PhoneLink] 输入心跳结束：{ex.Message}");
            }
        }, cts.Token);
    }

    /// <summary>IDENT 载荷：优先让手机用蓝牙 MAC 当会话键，保持历史转发组不失配</summary>
    private static string BuildIdent(bool wifi, bool dataRole, bool inputRole = false)
    {
        var payload = new Dictionary<string, object?>
        {
            ["id"] = RelaySettings.LocalPeerId(),
            ["bt"] = LocalBluetoothAddress(),
            ["platform"] = "win",
            ["transport"] = wifi ? "tcp" : "bt",
        };
        // 只有独立数据链路/输入车道才带 role；兜底整条 TCP 会话必须保持旧行为
        if (dataRole) payload["role"] = "data";
        else if (inputRole) payload["role"] = "input";
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }

    /// <summary>本机蓝牙适配器地址（拿不到就返回 null，手机退回用 id）</summary>
    private static string? LocalBluetoothAddress()
    {
        try
        {
            // 32feet 4.1.40 的 .NET 8 构建里没有 BluetoothRadio.PrimaryRadio，
            // 这里改用项目 TFM 自带的 WinRT 适配器接口（PairedDevices.cs 已在用同名空间）。
            var adapter = Windows.Devices.Bluetooth.BluetoothAdapter
                .GetDefaultAsync().AsTask().GetAwaiter().GetResult();
            var value = adapter?.BluetoothAddress ?? 0;
            if (value == 0) return null;
            var bytes = new[]
            {
                (byte)(value >> 40), (byte)(value >> 32), (byte)(value >> 24),
                (byte)(value >> 16), (byte)(value >> 8), (byte)value,
            };
            return string.Join(":", bytes.Select(b => b.ToString("X2")));
        }
        catch
        {
            // 未打包的桌面程序可能拿不到适配器信息；返回 null 由 id 兜底
            return null;
        }
    }

    private void StartReadLoop()
    {
        var cts = new CancellationTokenSource();
        lock (_gate)
        {
            _readCts?.Dispose();
            _readCts = cts;
        }
        var token = cts.Token;

        _ = Task.Run(async () =>
        {
            var assembler = new FileAssembler();
            try
            {
                while (!token.IsCancellationRequested && IsConnected)
                {
                    var stream = _transport?.Stream;
                    if (stream is null) break;

                    var frame = await Task.Run(() => Protocol.Read(stream), token);
                    if (frame is null)
                    {
                        RelayLog.Write("读循环：流结束（帧头无效或对端关闭）");
                        break;
                    }
                    // 文件分块太密，只记类型不记长度
                    if (frame.Type != Protocol.FrameType.FileChunk)
                    {
                        RelayLog.Write($"收到帧 {frame.Type} {frame.Payload.Length}B");
                    }
                    await HandleFrameAsync(frame, assembler, token);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                RelayLog.Write($"读循环异常：{ex.Message}");
            }
            finally
            {
                // 读循环自己结束 = 手机掉线（主动断开时 IsConnected 已先置 false）
                var lost = IsConnected && _role == PhoneLinkRole.Control;
                Disconnect();
                if (lost) ControlLinkLost?.Invoke();
            }
        }, token);
    }

    private async Task HandleFrameAsync(Protocol.Frame frame, FileAssembler assembler, CancellationToken ct)
    {
        switch (frame.Type)
        {
            case Protocol.FrameType.Text:
                var text = Encoding.UTF8.GetString(frame.Payload);
                TextReceived?.Invoke(text);
                if (frame.NeedAck) await SendAsync(Protocol.Ack(frame.Type), ct);
                break;

            case Protocol.FrameType.Config:
            {
                long max = RelaySettings.DefaultMaxBytes;
                try
                {
                    var obj = System.Text.Json.JsonDocument.Parse(Encoding.UTF8.GetString(frame.Payload)).RootElement;
                    if (obj.TryGetProperty("maxBytes", out var m) && m.TryGetInt64(out var v)) max = v;
                }
                catch (Exception ex)
                {
                    RelayLog.Write($"CONFIG 解析失败：{ex.Message}");
                }
                if (max < 0) max = 0;
                RelaySettings.SaveMaxBytes(max);
                RelayLog.Write($"手机下发传输上限：{(max == 0 ? Strings.Unlimited : $"{max} B")}");
                MaxBytesChanged?.Invoke(max);
                if (frame.NeedAck) await SendAsync(Protocol.Ack(frame.Type), ct);
                break;
            }

            case Protocol.FrameType.NetInfo:
                HandleNetInfo(frame);
                break;

            case Protocol.FrameType.Notification:
            {
                try
                {
                    var obj = System.Text.Json.JsonDocument.Parse(Encoding.UTF8.GetString(frame.Payload)).RootElement;
                    var app = obj.TryGetProperty("app", out var a) ? a.GetString() ?? "" : "";
                    var title = obj.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "";
                    var body = obj.TryGetProperty("text", out var x) ? x.GetString() ?? "" : "";
                    if (title.Length == 0 && body.Length == 0) break;
                    NotificationReceived?.Invoke(app, title, body);
                }
                catch (Exception ex)
                {
                    RelayLog.Write($"通知镜像解析失败：{ex.Message}");
                }
                break;
            }

            case Protocol.FrameType.Clipboard:
            {
                try
                {
                    var obj = System.Text.Json.JsonDocument.Parse(Encoding.UTF8.GetString(frame.Payload)).RootElement;
                    if (obj.TryGetProperty("text", out var value))
                    {
                        // 不能叫 text：switch 各分支共享作用域，TEXT 分支已经用掉了这个名字
                        var clipText = value.GetString();
                        if (!string.IsNullOrEmpty(clipText)) ClipboardReceived?.Invoke(clipText);
                    }
                }
                catch (Exception ex)
                {
                    RelayLog.Write($"剪贴板同步解析失败：{ex.Message}");
                }
                break;
            }

            // 设备策略：缓存到本地，蓝牙控制链路断开时据此决定是否锁屏
            case Protocol.FrameType.DevicePolicy:
            {
                try
                {
                    var obj = System.Text.Json.JsonDocument.Parse(Encoding.UTF8.GetString(frame.Payload)).RootElement;
                    if (obj.TryGetProperty("lockOnDisconnect", out var lk) &&
                        (lk.ValueKind == System.Text.Json.JsonValueKind.True ||
                         lk.ValueKind == System.Text.Json.JsonValueKind.False))
                    {
                        var on = lk.ValueKind == System.Text.Json.JsonValueKind.True;
                        LockOnDisconnect = on;
                        RelaySettings.SaveLockOnDisconnect(on);
                        RelayLog.Write($"设备策略：断开后锁屏 = {on}");
                    }
                }
                catch (Exception ex)
                {
                    RelayLog.Write($"设备策略解析失败：{ex.Message}");
                }
                break;
            }

            case Protocol.FrameType.BatchMeta:
            {
                try
                {
                    var obj = System.Text.Json.JsonDocument.Parse(Encoding.UTF8.GetString(frame.Payload)).RootElement;
                    var id = obj.TryGetProperty("id", out var i) ? i.GetString() : null;
                    if (string.IsNullOrEmpty(id))
                    {
                        RelayLog.Write("BATCH_META 缺少 id，已忽略");
                        break;
                    }
                    var files = obj.TryGetProperty("files", out var f) && f.TryGetInt32(out var fc) ? fc : 0;
                    var bytes = obj.TryGetProperty("bytes", out var b) && b.TryGetInt64(out var bc) ? bc : 0;

                    var dirs = new List<string>();
                    if (obj.TryGetProperty("dirs", out var d) && d.ValueKind == System.Text.Json.JsonValueKind.Array)
                    {
                        foreach (var dir in d.EnumerateArray())
                        {
                            var raw = dir.GetString();
                            if (!string.IsNullOrEmpty(raw)) dirs.Add(SanitizeRelativePath(raw));
                        }
                    }

                    var folder = obj.TryGetProperty("name", out var n) ? n.GetString() : null;
                    _batch = new BatchReceiver
                    {
                        Id = id,
                        Folder = UniqueFolderName(SanitizeSegment(folder ?? Strings.DefaultFolderName)),
                        Dirs = dirs,
                    };
                    _pendingRelativePath = null;
                    _ignoreCurrentFile = false;

                    var max = RelaySettings.LoadMaxBytes();
                    if (max > 0 && bytes > max)
                    {
                        _batch.Discarding = true;
                        RelayLog.Write($"批次 {id} 声明 {bytes} B 超过上限 {max} B，已丢弃");
                        await SendAsync(Protocol.Error($"batch exceeds maxBytes ({bytes} > {max})"), ct);
                    }
                    else
                    {
                        RelayLog.Write($"开始接收文件夹 {_batch.Folder}（{files} 个文件，{bytes} B）");
                    }
                }
                catch (Exception ex)
                {
                    RelayLog.Write($"BATCH_META 解析失败：{ex.Message}");
                }
                break;
            }

            case Protocol.FrameType.FileMeta:
            {
                var obj = System.Text.Json.JsonDocument.Parse(Encoding.UTF8.GetString(frame.Payload)).RootElement;
                var name = obj.TryGetProperty("name", out var n) ? n.GetString() ?? "file" : "file";
                var size = obj.TryGetProperty("size", out var s) && s.TryGetInt64(out var sv) ? sv : -1;
                var relPath = obj.TryGetProperty("path", out var p) && p.ValueKind == System.Text.Json.JsonValueKind.String
                    ? p.GetString() : null;
                var batchId = obj.TryGetProperty("batch", out var b) && b.ValueKind == System.Text.Json.JsonValueKind.String
                    ? b.GetString() : null;

                _pendingRelativePath = null;
                _ignoreCurrentFile = false;

                var batch = _batch;
                var inBatch = batch is not null && !string.IsNullOrEmpty(batchId)
                    && string.Equals(batchId, batch.Id, StringComparison.Ordinal);

                if (inBatch)
                {
                    if (batch!.Discarding)
                    {
                        // 批次已超限：仍消费后续帧保持流对齐，但不落盘
                        _ignoreCurrentFile = true;
                        break;
                    }
                    var max = RelaySettings.LoadMaxBytes();
                    if (max > 0 && size > max)
                    {
                        batch.Discarding = true;
                        _ignoreCurrentFile = true;
                        RelayLog.Write($"批次 {batch.Id} 中文件 {name} 超过上限 {max} B，丢弃整批");
                        await SendAsync(Protocol.Error($"file exceeds maxBytes ({size} > {max})"), ct);
                        break;
                    }
                    _pendingRelativePath = SanitizeRelativePath(relPath ?? name);
                }
                assembler.Begin(name, size);
                break;
            }

            case Protocol.FrameType.FileChunk:
                if (!_ignoreCurrentFile) assembler.Append(frame.Payload);
                break;

            case Protocol.FrameType.FileEnd:
            {
                if (_ignoreCurrentFile)
                {
                    _ignoreCurrentFile = false;
                    _pendingRelativePath = null;
                    if (frame.NeedAck) await SendAsync(Protocol.Ack(frame.Type), ct);
                    break;
                }

                var batch = _batch;
                var rel = _pendingRelativePath;
                _pendingRelativePath = null;

                if (batch is not null && rel is not null)
                {
                    try
                    {
                        var dir = Path.Combine(GetReceiveDir(), batch.Folder);
                        var relDir = Path.GetDirectoryName(rel.Replace('/', Path.DirectorySeparatorChar));
                        if (!string.IsNullOrEmpty(relDir)) dir = Path.Combine(dir, relDir);
                        Directory.CreateDirectory(dir);
                        var saved = assembler.SaveTo(dir);
                        batch.ReceivedFiles++;
                        batch.ReceivedBytes += assembler.Received;
                        RelayLog.Write($"批次 {batch.Id} 收到文件 {saved}");
                    }
                    catch (Exception ex)
                    {
                        batch.Discarding = true;
                        RelayLog.Write($"批次 {batch.Id} 落盘失败：{ex.Message}");
                        await SendAsync(Protocol.Error("save file failed"), ct);
                    }
                }
                else
                {
                    var path = assembler.SaveTo(GetReceiveDir());
                    FileReceived?.Invoke(path, assembler.Received);
                }

                if (frame.NeedAck) await SendAsync(Protocol.Ack(frame.Type), ct);
                break;
            }

            case Protocol.FrameType.BatchEnd:
            {
                var batch = _batch;
                try
                {
                    var obj = System.Text.Json.JsonDocument.Parse(Encoding.UTF8.GetString(frame.Payload)).RootElement;
                    var id = obj.TryGetProperty("id", out var i) ? i.GetString() : null;
                    if (batch is not null && string.Equals(id, batch.Id, StringComparison.Ordinal))
                    {
                        _batch = null;
                        _pendingRelativePath = null;
                        _ignoreCurrentFile = false;
                        if (!batch.Discarding)
                        {
                            CreateBatchDirectories(batch);
                            RelayLog.Write($"文件夹 {batch.Folder} 接收完成：{batch.ReceivedFiles} 个文件，{batch.ReceivedBytes} B");
                            FolderReceived?.Invoke(batch.Folder, batch.ReceivedFiles);
                        }
                    }
                    else
                    {
                        RelayLog.Write($"BATCH_END id 不匹配（{id ?? "null"}），已忽略");
                        _batch = null;
                    }
                }
                catch (Exception ex)
                {
                    RelayLog.Write($"BATCH_END 解析失败：{ex.Message}");
                }
                if (frame.NeedAck) await SendAsync(Protocol.Ack(frame.Type), ct);
                break;
            }

            case Protocol.FrameType.Ping:
                await SendAsync(Protocol.Pong(), ct);
                break;

            // 手机下发的脚本步骤：本机用 SendInput 注入，执行完回 ACK
            case Protocol.FrameType.ScriptStep:
            {
                var stepId = "";
                var ok = false;
                string? err = null;
                try
                {
                    using var doc = System.Text.Json.JsonDocument
                        .Parse(Encoding.UTF8.GetString(frame.Payload));
                    var root = doc.RootElement;
                    stepId = root.TryGetProperty("id", out var i) ? i.GetString() ?? "" : "";
                    ScriptRunner.Execute(root);
                    ok = true;
                }
                catch (Exception ex)
                {
                    err = ex.Message;
                    RelayLog.Write($"脚本步骤执行失败：{ex.Message}");
                }
                await SendAsync(Protocol.ScriptStepAck(stepId, ok, err), ct);
                break;
            }

            // 手机发起录制：开始/结束都由它控制，结束时把整份脚本一起回传
            case Protocol.FrameType.RecordCtrl:
            {
                var on = false;
                try
                {
                    using var doc = System.Text.Json.JsonDocument
                        .Parse(Encoding.UTF8.GetString(frame.Payload));
                    on = doc.RootElement.TryGetProperty("on", out var v) &&
                         v.ValueKind == System.Text.Json.JsonValueKind.True;
                }
                catch (Exception ex)
                {
                    RelayLog.Write($"录制指令解析失败：{ex.Message}");
                }

                if (on)
                {
                    var started = ScriptRecorder.Start();
                    RelayLog.Write(started ? "开始录制脚本" : "录制启动失败（钩子安装被拒绝）");
                    await SendAsync(Protocol.RecordResult(
                        ok: started,
                        recording: started,
                        err: started ? null : "无法安装键盘钩子（可能被安全软件拦截）"), ct);
                }
                else
                {
                    var result = ScriptRecorder.Stop();
                    if (result == null)
                    {
                        await SendAsync(Protocol.RecordResult(
                            ok: false, recording: false, err: "没有录到任何操作"), ct);
                    }
                    else
                    {
                        RelayLog.Write($"录制完成：{result.Steps} 步，已保存 {result.FilePath}");
                        await SendAsync(Protocol.RecordResult(
                            ok: true,
                            recording: false,
                            name: result.Name,
                            scriptJson: result.ScriptJson), ct);
                    }
                }
                break;
            }

            // 实时键鼠输入：直接注入，不逐条 ACK；每 100ms 回一次已应用序号
            case Protocol.FrameType.LiveInput:
            {
                var (applied, ok) = ScriptRunner.ApplyLive(Encoding.UTF8.GetString(frame.Payload));
                Interlocked.Exchange(ref _lastAppliedSeq, applied);
                var now = Environment.TickCount64;
                if (!ok || now - _lastInputStateAt >= 100)
                {
                    _lastInputStateAt = now;
                    await SendAsync(Protocol.InputState(applied, 0, ok), ct);
                }
                break;
            }

            case Protocol.FrameType.Error:
                Debug.WriteLine($"[PhoneLink] 手机端错误：{Encoding.UTF8.GetString(frame.Payload)}");
                break;
        }
    }

    /// <summary>
    /// 手机下发的 TCP 数据通道端点。
    ///
    /// 双通道模式下蓝牙控制链路必须常驻：这里只记住端点并唤醒数据链路，
    /// 绝不断开蓝牙。分块大小只对 TCP 生效，蓝牙固定 4 KB。
    /// </summary>
    private void HandleNetInfo(Protocol.Frame frame)
    {
        try
        {
            var obj = System.Text.Json.JsonDocument
                .Parse(Encoding.UTF8.GetString(frame.Payload)).RootElement;

            var port = obj.TryGetProperty("port", out var p) && p.TryGetInt32(out var pv) ? pv : 0;
            var chunk = obj.TryGetProperty("chunk", out var c) && c.TryGetInt32(out var cv)
                ? cv : RelaySettings.DefaultTcpChunk;

            var ips = new List<string>();
            if (obj.TryGetProperty("ips", out var arr) &&
                arr.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                foreach (var item in arr.EnumerateArray())
                {
                    var text = item.GetString();
                    if (!string.IsNullOrWhiteSpace(text)) ips.Add(text);
                }
            }

            if (port <= 0 || ips.Count == 0)
            {
                // 手机没连 Wi-Fi：控制链路继续走蓝牙；兜底 TCP 会话不用清自己的端点
                if (_role == PhoneLinkRole.Control && !IsWifi)
                {
                    _hasWifiEndpoint = false;
                    RelaySettings.ClearWifiEndpoint();
                    RelayLog.Write("手机未提供数据通道端点（可能没连 Wi-Fi），继续走蓝牙");
                }
                return;
            }

            var host = PreferLanAddress(ips);
            if (chunk > 0)
            {
                var clamped = Math.Clamp(chunk, Protocol.MaxChunk, 256 * 1024);
                RelaySettings.SaveWifiChunk(clamped);
                // 只有当前就在 TCP 上的链路才立即改用新分块
                if (_role == PhoneLinkRole.Data || IsWifi) _chunkSize = clamped;
            }

            RelaySettings.SaveWifiEndpoint(host, port);

            if (_role == PhoneLinkRole.Data)
            {
                // 已经在这条数据链路上；端点若变化，下次断线重连会自动用新地址
                return;
            }

            _hasWifiEndpoint = true;
            RelayLog.Write($"手机提供数据通道端点 {host}:{port}");
            NetworkEndpointUpdated?.Invoke();
        }
        catch (Exception ex)
        {
            RelayLog.Write($"NET_INFO 解析失败：{ex.Message}");
        }
    }

    /// <summary>多网卡时优先内网地址（192.168 / 10 / 172.16-31），其余按原顺序兜底</summary>
    private static string PreferLanAddress(IReadOnlyList<string> ips)
    {
        foreach (var ip in ips)
        {
            if (ip.StartsWith("192.168.", StringComparison.Ordinal) ||
                ip.StartsWith("10.", StringComparison.Ordinal))
                return ip;
        }
        foreach (var ip in ips)
        {
            if (!ip.StartsWith("172.", StringComparison.Ordinal)) continue;
            var parts = ip.Split('.');
            if (parts.Length > 1 && int.TryParse(parts[1], out var second) && second is >= 16 and <= 31)
                return ip;
        }
        return ips[0];
    }

    /// <summary>发送文本到手机（文本始终走蓝牙控制链路）</summary>
    public async Task SendTextAsync(string content)
    {
        if (!IsConnected) throw new IOException(Strings.NotConnected);
        await _sequenceLock.WaitAsync(CancellationToken.None);
        try
        {
            await SendAsync(Protocol.Text(content), CancellationToken.None);
        }
        finally
        {
            _sequenceLock.Release();
        }
    }

    /// <summary>
    /// 发送剪贴板文本：静默同步，未连接或内容超限时直接丢弃（不弹提示，避免自动同步打断用户）
    /// </summary>
    public async Task SendClipboardAsync(string text)
    {
        if (!IsConnected || string.IsNullOrEmpty(text) || text.Length > 64 * 1024) return;
        var json = System.Text.Json.JsonSerializer.Serialize(new { text });
        await _sequenceLock.WaitAsync(CancellationToken.None);
        try
        {
            await SendAsync(Protocol.ClipboardJson(json), CancellationToken.None);
        }
        catch (Exception ex)
        {
            RelayLog.Write($"发送剪贴板失败：{ex.Message}");
        }
        finally
        {
            _sequenceLock.Release();
        }
    }

    /// <summary>
    /// 发送前等 Wi-Fi 数据链路就绪（不区分文件大小）。
    ///
    /// 手机下发 NET_INFO 后 PC 才开始建 TCP，用户刚好在这段时间点发送时，
    /// 直接走蓝牙会让小文件看起来「优先蓝牙」。这里给 TCP 3 秒优先窗口，
    /// 等不到才兜底；连续等不到则冷却 30 秒，避免没有 Wi-Fi 时每个文件都等。
    /// </summary>
    private async Task<PhoneLink?> WaitForDataLinkAsync(CancellationToken ct)
    {
        if (DataLink is { IsConnected: true } connected) return connected;
        if (_role != PhoneLinkRole.Control || !_hasWifiEndpoint) return null;
        if (DateTime.UtcNow < _noDataLinkUntil) return null;

        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(3);
        while (DateTime.UtcNow < deadline)
        {
            if (DataLink is { IsConnected: true } link) return link;
            await Task.Delay(100, ct);
        }
        _noDataLinkUntil = DateTime.UtcNow.AddSeconds(30);
        RelayLog.Write("TCP 数据链路未就绪，本次文件改走蓝牙");
        return null;
    }

    /// <summary>发送文件到手机（优先 TCP，等不到数据链路才走蓝牙）</summary>
    public async Task SendFileAsync(string path)
    {
        if (DataLink is { IsConnected: true } data)
        {
            await data.SendFileAsync(path);
            return;
        }

        if (await WaitForDataLinkAsync(CancellationToken.None) is { } link)
        {
            await link.SendFileAsync(path);
            return;
        }

        if (!IsConnected) throw new IOException(Strings.NotConnected);
        var bytes = await File.ReadAllBytesAsync(path);
        var name = Path.GetFileName(path);
        var meta = System.Text.Json.JsonSerializer.Serialize(
            new { name, size = bytes.Length },
            new System.Text.Json.JsonSerializerOptions
            {
                PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
            });

        await _sequenceLock.WaitAsync(CancellationToken.None);
        try
        {
            await SendAsync(Protocol.FileMeta(meta), CancellationToken.None);
            for (int off = 0; off < bytes.Length; off += _chunkSize)
            {
                int len = Math.Min(_chunkSize, bytes.Length - off);
                await SendAsync(Protocol.Chunk(bytes, off, len), CancellationToken.None);
            }
            await SendAsync(Protocol.FileEnd(), CancellationToken.None);
        }
        finally
        {
            _sequenceLock.Release();
        }
    }

    /// <summary>文件夹发送结果（供托盘提示跳过数量）</summary>
    public sealed record FolderSendResult(string FolderName, int FileCount, long Bytes, int Skipped);

    /// <summary>
    /// 发送整个文件夹：BATCH_META →（FILE_META + CHUNK* + FILE_END）* → BATCH_END。
    /// 相对路径使用正斜杠；符号链接/不可读文件跳过，数量随结果返回。
    /// </summary>
    public async Task<FolderSendResult> SendFolderAsync(string folderPath, CancellationToken ct = default)
    {
        if (DataLink is { IsConnected: true } data)
            return await data.SendFolderAsync(folderPath, ct);

        if (await WaitForDataLinkAsync(ct) is { } link)
            return await link.SendFolderAsync(folderPath, ct);

        if (!IsConnected) throw new IOException(Strings.NotConnected);
        if (!Directory.Exists(folderPath)) throw new IOException("Folder does not exist");

        var root = new DirectoryInfo(folderPath);
        var folderName = SanitizeSegment(root.Name);
        var files = new List<CollectedFile>();
        var dirs = new List<string>();
        var skipped = CollectDirectory(root, "", files, dirs);

        long totalBytes = files.Sum(f => f.Size);
        var max = RelaySettings.LoadMaxBytes();
        if (max > 0 && totalBytes > max)
            throw new IOException(
                $"Folder {Strings.FormatSize(totalBytes)} exceeds transfer limit {Strings.FormatSize(max)}");

        var id = Guid.NewGuid().ToString("N")[..8];

        await _sequenceLock.WaitAsync(ct);
        try
        {
            await SendAsync(Protocol.BatchMeta(id, folderName, files.Count, totalBytes, dirs), ct);

            int sent = 0;
            foreach (var file in files)
            {
                byte[] bytes;
                try
                {
                    bytes = await File.ReadAllBytesAsync(file.FullPath, ct);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    skipped++;
                    RelayLog.Write($"发送文件夹跳过 {file.RelativePath}：{ex.Message}");
                    continue;
                }

                var name = Path.GetFileName(file.RelativePath.Replace('/', Path.DirectorySeparatorChar));
                await SendAsync(Protocol.FileMeta(name, bytes.Length, file.RelativePath, id), ct);
                for (int off = 0; off < bytes.Length; off += _chunkSize)
                {
                    int len = Math.Min(_chunkSize, bytes.Length - off);
                    await SendAsync(Protocol.Chunk(bytes, off, len), ct);
                }
                await SendAsync(Protocol.FileEnd(), ct);
                sent++;
            }

            await SendAsync(Protocol.BatchEnd(id, sent), ct);
            RelayLog.Write($"已发送文件夹 {folderName}：{sent} 个文件，{totalBytes} B，跳过 {skipped}");
            return new FolderSendResult(folderName, sent, totalBytes, skipped);
        }
        finally
        {
            _sequenceLock.Release();
        }
    }

    private sealed record CollectedFile(string FullPath, string RelativePath, long Size);

    /// <summary>递归枚举文件夹（含空目录），跳过符号链接与不可读项；返回跳过数量</summary>
    private static int CollectDirectory(
        DirectoryInfo dir, string relPrefix, List<CollectedFile> files, List<string> dirs)
    {
        int skipped = 0;
        try
        {
            foreach (var sub in dir.EnumerateDirectories())
            {
                try
                {
                    sub.Refresh();
                    if ((sub.Attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        skipped++;
                        continue;
                    }
                    var rel = JoinRelative(relPrefix, sub.Name);
                    dirs.Add(rel);
                    skipped += CollectDirectory(sub, rel, files, dirs);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    skipped++;
                    RelayLog.Write($"跳过目录 {sub.FullName}：{ex.Message}");
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            skipped++;
            RelayLog.Write($"枚举目录 {dir.FullName} 失败：{ex.Message}");
        }

        try
        {
            foreach (var file in dir.EnumerateFiles())
            {
                try
                {
                    if ((file.Attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        skipped++;
                        continue;
                    }
                    using var probe = file.OpenRead();   // 预检可读性，避免批次中途失败
                    var size = probe.Length;
                    files.Add(new CollectedFile(
                        file.FullName, JoinRelative(relPrefix, file.Name), size));
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    skipped++;
                    RelayLog.Write($"跳过文件 {file.FullName}：{ex.Message}");
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            skipped++;
            RelayLog.Write($"枚举文件 {dir.FullName} 失败：{ex.Message}");
        }

        return skipped;
    }

    private static string JoinRelative(string prefix, string name) =>
        prefix.Length == 0 ? name : $"{prefix}/{name}";

    private static string FormatSize(long bytes) => bytes switch
    {
        >= 1024 * 1024 => $"{bytes / 1024f / 1024f:F1} MB",
        >= 1024 => $"{bytes / 1024f:F1} KB",
        _ => $"{bytes} B",
    };

    /// <summary>清洗单个路径段：去掉非法字符，拒绝 "." / ".."</summary>
    private static string SanitizeSegment(string segment)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var sb = new StringBuilder(segment.Length);
        foreach (var ch in segment)
            sb.Append(ch is '/' or '\\' || invalid.Contains(ch) ? '_' : ch);
        var safe = sb.ToString().Trim();
        if (safe.Length == 0 || safe == "." || safe == "..") safe = "_";
        return safe;
    }

    /// <summary>清洗相对路径（正斜杠分段），丢弃 ".." 段</summary>
    private static string SanitizeRelativePath(string relative)
    {
        var list = new List<string>();
        foreach (var part in relative.Split(new[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == "." || part == "..") continue;
            list.Add(SanitizeSegment(part));
        }
        return list.Count == 0 ? "_" : string.Join('/', list);
    }

    /// <summary>接收目录内同名文件夹自动加序号：photos → photos (1)</summary>
    private static string UniqueFolderName(string name)
    {
        var root = GetReceiveDir();
        if (!Directory.Exists(Path.Combine(root, name))) return name;
        for (var i = 1; i < 10000; i++)
        {
            var candidate = $"{name} ({i})";
            if (!Directory.Exists(Path.Combine(root, candidate))) return candidate;
        }
        return $"{name} (10000)";
    }

    private static void CreateBatchDirectories(BatchReceiver batch)
    {
        try
        {
            var root = Path.Combine(GetReceiveDir(), batch.Folder);
            Directory.CreateDirectory(root);
            foreach (var rel in batch.Dirs)
            {
                try
                {
                    Directory.CreateDirectory(
                        Path.Combine(root, rel.Replace('/', Path.DirectorySeparatorChar)));
                }
                catch (Exception ex)
                {
                    RelayLog.Write($"创建目录 {rel} 失败：{ex.Message}");
                }
            }
        }
        catch (Exception ex)
        {
            RelayLog.Write($"创建文件夹 {batch.Folder} 失败：{ex.Message}");
        }
    }

    private sealed class BatchReceiver
    {
        public string Id { get; init; } = "";
        public string Folder { get; init; } = "";
        public List<string> Dirs { get; init; } = new();
        public int ReceivedFiles { get; set; }
        public long ReceivedBytes { get; set; }
        public bool Discarding { get; set; }
    }

    private async Task SendAsync(Protocol.Frame frame, CancellationToken ct)
    {
        var stream = _transport?.Stream ?? throw new IOException("Connection not established");
        await _sendLock.WaitAsync(ct);
        try
        {
            await Task.Run(() => Protocol.Write(stream, frame), ct);
        }
        finally
        {
            _sendLock.Release();
        }
    }

    public void Disconnect() => DisconnectCore(notify: true);

    /// <summary>
    /// 断开当前通道。
    /// <paramref name="notify"/> = false 时不上报「已断开」——从蓝牙切到 Wi-Fi 时用，
    /// 否则托盘会闪一条「手机已断开」的提示，其实只是换了条通道。
    /// </summary>
    private void DisconnectCore(bool notify)
    {
        bool wasConnected;
        lock (_gate)
        {
            wasConnected = IsConnected;
            IsConnected = false;
            ConnectedAddress = null;

            // 断线时丢弃未完成的文件夹批次，避免重连后 path/batch 串到新连接
            _batch = null;
            _pendingRelativePath = null;
            _ignoreCurrentFile = false;

            var transport = _transport;
            _transport = null;

            try { _readCts?.Cancel(); } catch { }
            try { _readCts?.Dispose(); } catch { }
            _readCts = null;

            try { _inputHeartbeat?.Cancel(); } catch { }
            try { _inputHeartbeat?.Dispose(); } catch { }
            _inputHeartbeat = null;

            try { transport?.Dispose(); } catch { }
        }

        if (wasConnected && notify && _role == PhoneLinkRole.Control)
            ConnectionChanged?.Invoke(false, PhoneName);
    }

    /// <summary>解析 12 位十六进制地址（32feet 的 Parse 会抛异常，这里统一兜住）</summary>
    private static bool TryParseAddress(string text, out BluetoothAddress address)
    {
        address = BluetoothAddress.None;
        try
        {
            address = BluetoothAddress.Parse(text);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>接收目录：Downloads\BlueDesk</summary>
    public static string GetReceiveDir()
    {
        var downloads = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        var dir = Path.Combine(downloads, "BlueDesk");
        Directory.CreateDirectory(dir);
        return dir;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Disconnect();
        _sendLock.Dispose();
        _sequenceLock.Dispose();
    }

    private readonly record struct PhoneTarget(BluetoothAddress Address, string Name);
}

/// <summary>文件接收组装器（FILE_META → CHUNK* → FILE_END）</summary>
public sealed class FileAssembler
{
    private readonly MemoryStream _buffer = new();
    public string Name { get; private set; } = "file";
    public long ExpectedSize { get; private set; } = -1;
    public long Received { get; private set; }

    public void Begin(string name, long size)
    {
        Name = name;
        ExpectedSize = size;
        _buffer.SetLength(0);
        Received = 0;
    }

    public void Append(byte[] data)
    {
        _buffer.Write(data, 0, data.Length);
        Received += data.Length;
    }

    /// <summary>落盘（同名自动加序号），返回完整路径</summary>
    public string SaveTo(string dir)
    {
        var safe = string.Join("_", Name.Split(Path.GetInvalidFileNameChars()));
        if (string.IsNullOrWhiteSpace(safe)) safe = "file";
        var path = Path.Combine(dir, safe);
        int i = 1;
        while (File.Exists(path))
        {
            var ext = Path.GetExtension(safe);
            path = Path.Combine(dir, $"{Path.GetFileNameWithoutExtension(safe)}({i++}){ext}");
        }
        using var fs = File.Create(path);
        _buffer.Position = 0;
        _buffer.CopyTo(fs);
        return path;
    }
}
