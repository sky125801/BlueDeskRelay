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

    private sealed class Model
    {
        public string? PhoneAddress { get; set; }
        public string? PhoneName { get; set; }
        /// <summary>手机统一下发的传输上限；0 = 不限</summary>
        public long MaxBytes { get; set; } = DefaultMaxBytes;
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
            Persist();
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
