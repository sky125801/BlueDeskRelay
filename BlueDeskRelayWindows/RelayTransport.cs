using System.Net.Sockets;
using InTheHand.Net.Sockets;

namespace BlueDeskRelay;

/// <summary>
/// 一条 PC ↔ 手机的数据通道。
///
/// 蓝牙 RFCOMM 与 Wi-Fi TCP 只是底层字节流不同，上面的帧协议完全一致，
/// 所以 <see cref="PhoneLink"/> 的收发、重连、批次逻辑都只认这个接口。
/// </summary>
internal interface IRelayTransport : IDisposable
{
    Stream Stream { get; }

    /// <summary>true = 走 Wi-Fi（TCP），false = 走蓝牙（RFCOMM）</summary>
    bool IsWifi { get; }

    /// <summary>界面与日志用的描述：「蓝牙」/「Wi-Fi 192.168.1.23:47654」</summary>
    string Description { get; }
}

internal sealed class BluetoothRelayTransport : IRelayTransport
{
    private readonly BluetoothClient _client;
    private readonly Stream _stream;

    public BluetoothRelayTransport(BluetoothClient client, Stream stream)
    {
        _client = client;
        _stream = stream;
    }

    public Stream Stream => _stream;

    public bool IsWifi => false;

    public string Description => "蓝牙";

    public void Dispose()
    {
        try { _stream.Dispose(); } catch { }
        try { _client.Dispose(); } catch { }
    }
}

internal sealed class TcpRelayTransport : IRelayTransport
{
    private readonly TcpClient _client;
    private readonly NetworkStream _stream;

    public TcpRelayTransport(TcpClient client)
    {
        _client = client;
        _stream = client.GetStream();
    }

    public Stream Stream => _stream;

    public bool IsWifi => true;

    public string Description => $"Wi-Fi {_client.Client.RemoteEndPoint}";

    public void Dispose()
    {
        try { _stream.Dispose(); } catch { }
        try { _client.Dispose(); } catch { }
    }
}
