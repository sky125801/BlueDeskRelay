using System.Diagnostics;
using System.Text;

namespace BlueDeskRelay;

/// <summary>一台已配对的蓝牙设备</summary>
public readonly record struct PairedDevice(string Name, string Address);

/// <summary>
/// 已配对设备枚举。
///
/// 为什么不用 32feet 的 <c>BluetoothClient.DiscoverDevices</c>：
/// 该 API 在 4.1.x 只有单参重载，每次都会做一次完整 inquiry（10~20 秒），
/// 放在托盘菜单展开路径上完全不可用。
///
/// 这里改用 WinRT 的 <c>DeviceInformation.FindAllAsync</c> 直接读系统配对缓存，
/// 毫秒级返回、不触发射频查询。地址统一转成 32feet 能解析的 12 位十六进制串，
/// 避免两套 API 之间 ulong/字节序不一致的坑。
/// </summary>
internal static class PairedDevices
{
    public static async Task<IReadOnlyList<PairedDevice>> ListAsync(CancellationToken ct = default)
    {
        var result = new List<PairedDevice>();
        try
        {
            var selector = Windows.Devices.Bluetooth.BluetoothDevice
                .GetDeviceSelectorFromPairingState(true);
            var infos = await Windows.Devices.Enumeration.DeviceInformation.FindAllAsync(selector);

            foreach (var info in infos)
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    var device = await Windows.Devices.Bluetooth.BluetoothDevice.FromIdAsync(info.Id);
                    if (device is null) continue;

                    var address = ToMacString(device.BluetoothAddress);
                    if (address.Length != 12) continue;

                    var name = string.IsNullOrWhiteSpace(device.Name) ? info.Name : device.Name;
                    if (string.IsNullOrWhiteSpace(name)) name = address;

                    if (result.All(x => !string.Equals(x.Address, address, StringComparison.OrdinalIgnoreCase)))
                        result.Add(new PairedDevice(name, address));
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[PairedDevices] 读取「{info.Name}」失败：{ex.Message}");
                }
            }
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            Debug.WriteLine($"[PairedDevices] 枚举已配对设备失败：{ex.Message}");
        }

        return result
            .OrderBy(x => x.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    /// <summary>WinRT 的 BluetoothAddress 是「高字节在前」的 48 位值，直接按 MSB→LSB 打印</summary>
    private static string ToMacString(ulong address)
    {
        var sb = new StringBuilder(12);
        for (int i = 5; i >= 0; i--)
            sb.Append(((address >> (8 * i)) & 0xFF).ToString("X2"));
        return sb.ToString();
    }
}
