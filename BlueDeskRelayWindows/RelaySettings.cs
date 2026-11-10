using System.Diagnostics;
using System.Text.Json;

namespace BlueDeskRelay;

/// <summary>
/// 极简本地配置：只记「上次连上的手机地址」。
///
/// 作用：蓝牙设备发现在 Windows 上要做一次 inquiry，耗时 10~20 秒。
/// 缓存地址后重连可以直连，1 秒内完成；地址失效（手机换机/取消配对）时
/// 由 <see cref="PhoneLink"/> 快速失败并回退到设备发现。
///
/// 位置：%APPDATA%\BlueDesk\relay.json
/// </summary>
internal static class RelaySettings
{
    /// <summary>手机未下发 CONFIG 时的默认传输上限（64 MB）</summary>
    public const long DefaultMaxBytes = 64L * 1024 * 1024;

    /// <summary>TCP 数据通道的默认分块大小；手机可通过 NET_INFO 的 chunk 字段覆盖</summary>
    public const int DefaultTcpChunk = 64 * 1024;

    private sealed class Model
    {
        public string? PhoneAddress { get; set; }
        public string? PhoneName { get; set; }
        /// <summary>手机统一下发的传输上限；0 = 不限</summary>
        public long MaxBytes { get; set; } = DefaultMaxBytes;
        /// <summary>手机 Wi-Fi 数据通道的地址（由手机通过 NET_INFO 下发）</summary>
        public string? WifiHost { get; set; }
        public int WifiPort { get; set; }
        /// <summary>TCP 数据通道分块大小（手机通过 NET_INFO 下发）</summary>
        public int WifiChunk { get; set; } = DefaultTcpChunk;
        /// <summary>本机稳定标识：TCP 接入时手机拿不到 MAC，靠它把会话认回同一台电脑</summary>
        public string? PeerId { get; set; }
    }

    private static readonly object Gate = new();
    private static Model? _cached;

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "BlueDesk", "relay.json");

    private static Model Current()
    {
        lock (Gate)
        {
            if (_cached is not null) return _cached;
            try
            {
                if (File.Exists(FilePath))
                {
                    var json = File.ReadAllText(FilePath);
                    _cached = JsonSerializer.Deserialize<Model>(json) ?? new Model();
                    return _cached;
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[RelaySettings] 读取配置失败：{ex.Message}");
            }
            _cached = new Model();
            return _cached;
        }
    }

    public static string? LoadPhoneAddress() => Current().PhoneAddress;

    public static string? LoadPhoneName() => Current().PhoneName;

    /// <summary>当前传输上限（字节）；0 表示不限。负数视为 0</summary>
    public static long LoadMaxBytes()
    {
        var value = Current().MaxBytes;
        return value < 0 ? 0 : value;
    }

    /// <summary>保存手机下发的传输上限（0 = 不限）</summary>
    public static void SaveMaxBytes(long maxBytes)
    {
        lock (Gate)
        {
            var model = Current();
            if (maxBytes < 0) maxBytes = 0;
            if (model.MaxBytes == maxBytes) return;
            model.MaxBytes = maxBytes;
            Persist();
        }
    }

    /// <summary>调用方须持有 <see cref="Gate"/></summary>
    private static void Persist()
    {
        try
        {
            var model = Current();
            var dir = Path.GetDirectoryName(FilePath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(model));
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[RelaySettings] 保存配置失败：{ex.Message}");
        }
    }

    /// <summary>清除「记忆设备」，恢复自动发现 BlueDesk* 手机（保留手机下发的传输上限）</summary>
    public static void Clear()
    {
        lock (Gate)
        {
            var model = Current();
            model.PhoneAddress = null;
            model.PhoneName = null;
            model.WifiHost = null;
            model.WifiPort = 0;
            Persist();
        }
    }

    // ------------------------------------------------------------
    // Wi-Fi 数据通道
    // ------------------------------------------------------------

    /// <summary>已记住的 Wi-Fi 端点；null 表示还没拿到（只能走蓝牙）</summary>
    public static (string Host, int Port)? LoadWifiEndpoint()
    {
        var model = Current();
        if (string.IsNullOrWhiteSpace(model.WifiHost) || model.WifiPort <= 0) return null;
        return (model.WifiHost, model.WifiPort);
    }

    public static void SaveWifiEndpoint(string host, int port)
    {
        lock (Gate)
        {
            var model = Current();
            if (model.WifiHost == host && model.WifiPort == port) return;
            model.WifiHost = host;
            model.WifiPort = port;
            Persist();
        }
    }

    /// <summary>忘掉端点：手机换了网络、或连续连不上时调用，下次靠蓝牙重新拿</summary>
    public static void ClearWifiEndpoint()
    {
        lock (Gate)
        {
            var model = Current();
            if (model.WifiHost is null && model.WifiPort == 0) return;
            model.WifiHost = null;
            model.WifiPort = 0;
            Persist();
        }
    }

    /// <summary>TCP 数据通道的分块大小（已按协议上限收敛）</summary>
    public static int LoadWifiChunk()
    {
        var value = Current().WifiChunk;
        if (value <= 0) return DefaultTcpChunk;
        return Math.Clamp(value, Protocol.MaxChunk, 256 * 1024);
    }

    public static void SaveWifiChunk(int chunk)
    {
        if (chunk <= 0) return;
        lock (Gate)
        {
            var model = Current();
            if (model.WifiChunk == chunk) return;
            model.WifiChunk = chunk;
            Persist();
        }
    }

    /// <summary>本机稳定标识（首次调用生成并持久化）</summary>
    public static string LocalPeerId()
    {
        lock (Gate)
        {
            var model = Current();
            if (!string.IsNullOrWhiteSpace(model.PeerId)) return model.PeerId;
            model.PeerId = Guid.NewGuid().ToString("N");
            Persist();
            return model.PeerId;
        }
    }

    public static void SavePhone(string address, string name)
    {
        lock (Gate)
        {
            var model = Current();
            if (model.PhoneAddress == address && model.PhoneName == name) return;
            model.PhoneAddress = address;
            model.PhoneName = name;
            try
            {
                var dir = Path.GetDirectoryName(FilePath)!;
                Directory.CreateDirectory(dir);
                File.WriteAllText(FilePath, JsonSerializer.Serialize(model));
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[RelaySettings] 保存配置失败：{ex.Message}");
            }
        }
    }
}
