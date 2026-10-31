using System.Diagnostics;
using System.Text;
using InTheHand.Net;
using InTheHand.Net.Bluetooth;
using InTheHand.Net.Sockets;

namespace BlueDeskRelay;

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
/// 由 <see cref="SuperviseAsync"/> 常驻守护，断线后自动重连。
/// </summary>
public sealed class PhoneLink : IDisposable
{
    /// <summary>直连缓存地址的超时（秒）——地址失效时要快速失败，好回退到设备发现</summary>
    private const int CachedConnectTimeoutSeconds = 6;

    /// <summary>设备发现后正式连接的超时（秒）</summary>
    private const int DiscoveredConnectTimeoutSeconds = 20;

    /// <summary>重连间隔</summary>
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(5);

    private readonly SemaphoreSlim _sendLock = new(1, 1);
    /// <summary>发送串行门：保证一个文件/一个文件夹批次的帧序列不与文本或其他文件交错</summary>
    private readonly SemaphoreSlim _sequenceLock = new(1, 1);
    private readonly SemaphoreSlim _wake = new(0, 1);
    private readonly object _gate = new();

    private BluetoothClient? _client;
    private Stream? _stream;
    private CancellationTokenSource? _readCts;
    private volatile bool _disposed;

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

    /// <summary>当前连接设备的地址（未连接为 null；菜单打勾用）</summary>
    public string? ConnectedAddress { get; private set; }

    /// <summary>收到文本（在后台线程回调，调用方需自行切到 UI 线程）</summary>
    public event Action<string>? TextReceived;

    /// <summary>收到文件（已完整落盘）</summary>
    public event Action<string, long>? FileReceived;

    /// <summary>手机下发传输上限（在后台线程回调，0 = 不限）</summary>
    public event Action<long>? MaxBytesChanged;

    /// <summary>整个文件夹批次接收完成（参数：文件夹名 / 实际文件数）</summary>
    public event Action<string, int>? FolderReceived;

    /// <summary>连接状态变化</summary>
    public event Action<bool, string>? ConnectionChanged;

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

        // 1) 先试上次成功的地址，避免每次都做全量蓝牙查询
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

        lock (_gate)
        {
            _client = client;
            _stream = stream;
            PhoneName = name;
            ConnectedAddress = address.ToString();
            IsConnected = true;
        }

        try
        {
            // 报身份（手机端 5 秒内收不到 HELLO 会主动断开）
            await SendAsync(Protocol.Hello(Environment.MachineName), ct);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[PhoneLink] HELLO 发送失败：{ex.Message}");
            Disconnect();
            return false;
        }

        RelaySettings.SavePhone(address.ToString(), name);
        ConnectionChanged?.Invoke(true, name);

        StartReadLoop();
        return true;
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
                    var stream = _stream;
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
                Disconnect();
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
                RelayLog.Write($"手机下发传输上限：{(max == 0 ? "不限" : $"{max} B")}");
                MaxBytesChanged?.Invoke(max);
                if (frame.NeedAck) await SendAsync(Protocol.Ack(frame.Type), ct);
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
                        Folder = UniqueFolderName(SanitizeSegment(folder ?? "文件夹")),
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

            case Protocol.FrameType.Error:
                Debug.WriteLine($"[PhoneLink] 手机端错误：{Encoding.UTF8.GetString(frame.Payload)}");
                break;
        }
    }

    /// <summary>发送文本到手机（手机 UI 会收到一条记录，可一键转发给另一台 PC）</summary>
    public async Task SendTextAsync(string content)
    {
        if (!IsConnected) throw new IOException("手机未连接");
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

    /// <summary>发送文件到手机</summary>
    public async Task SendFileAsync(string path)
    {
        if (!IsConnected) throw new IOException("手机未连接");
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
            for (int off = 0; off < bytes.Length; off += Protocol.MaxChunk)
            {
                int len = Math.Min(Protocol.MaxChunk, bytes.Length - off);
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
        if (!IsConnected) throw new IOException("手机未连接");
        if (!Directory.Exists(folderPath)) throw new IOException("文件夹不存在");

        var root = new DirectoryInfo(folderPath);
        var folderName = SanitizeSegment(root.Name);
        var files = new List<CollectedFile>();
        var dirs = new List<string>();
        var skipped = CollectDirectory(root, "", files, dirs);

        long totalBytes = files.Sum(f => f.Size);
        var max = RelaySettings.LoadMaxBytes();
        if (max > 0 && totalBytes > max)
            throw new IOException(
                $"文件夹共 {FormatSize(totalBytes)}，超过传输上限 {FormatSize(max)}，已取消发送");

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
                for (int off = 0; off < bytes.Length; off += Protocol.MaxChunk)
                {
                    int len = Math.Min(Protocol.MaxChunk, bytes.Length - off);
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
        var stream = _stream ?? throw new IOException("连接未建立");
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

    public void Disconnect()
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

            var stream = _stream;
            var client = _client;
            _stream = null;
            _client = null;

            try { _readCts?.Cancel(); } catch { }
            try { _readCts?.Dispose(); } catch { }
            _readCts = null;

            try { stream?.Dispose(); } catch { }
            try { client?.Dispose(); } catch { }
        }

        if (wasConnected) ConnectionChanged?.Invoke(false, PhoneName);
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
