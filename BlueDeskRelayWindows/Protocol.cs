using System.Text;
using System.Text.Json;

namespace BlueDeskRelay;

/// <summary>
/// BlueDesk 中转传输协议（手机端实现）—— 与手机侧逐字节对齐。
///
/// 帧格式（定长 11 字节头 + 载荷）：
///   0  2  MAGIC = 0xBD 0x54
///   2  1  VER = 1
///   3  1  TYPE（见 FrameType）
///   4  1  FLAGS（bit0 = 需要回 ACK）
///   5  4  PAYLOAD_LEN（u32 大端）
///   9  2  CRC32 低 16 位（大端；空载荷 0xFFFF）
///   11 n  payload
/// </summary>
public static class Protocol
{
    public const int HeaderSize = 11;
    public const int MaxChunk = 4 * 1024;

    /// <summary>与手机端 TransferProtocol.SERVICE_UUID 一致</summary>
    public static readonly Guid ServiceUuid = new("a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1");

    public static class FrameType
    {
        public const byte Hello = 0x01;
        public const byte Text = 0x02;
        public const byte FileMeta = 0x03;
        public const byte FileChunk = 0x04;
        public const byte FileEnd = 0x05;
        public const byte Ack = 0x06;
        public const byte Ping = 0x07;
        public const byte Pong = 0x08;
        public const byte Error = 0x09;
        public const byte Config = 0x0A;
        public const byte BatchMeta = 0x0B;
        public const byte BatchEnd = 0x0C;

        /// <summary>网络端点（手机 → PC）：{"port":47654,"ips":["192.168.1.23"],"name":"BlueDesk-A1B2C3"}</summary>
        public const byte NetInfo = 0x0D;

        /// <summary>
        /// 身份补充（PC → 手机）：{"id":"uuid","bt":"AA:BB:..","platform":"win","transport":"tcp"}。
        /// 独立 TCP 数据链路额外带 "role":"data"，手机据此挂到蓝牙控制会话上而不断开蓝牙；
        /// 不带 role 表示旧版「整条会话切 TCP」。
        /// </summary>
        public const byte Ident = 0x0E;

        /// <summary>代理能力宣告（PC → 手机）：{"script":1,"platform":"win","unicode":1,"secure":0|1}</summary>
        public const byte AgentInfo = 0x0F;

        /// <summary>
        /// 脚本步骤（手机 → PC）：{"id","t","x","y","abs","w","k","txt"}。
        /// 坐标是 1280×720 逻辑坐标，由本机换算成屏幕绝对坐标；文本走 Unicode 注入。
        /// </summary>
        public const byte ScriptStep = 0x10;

        /// <summary>脚本步骤结果（PC → 手机）：{"id","ok","err"}</summary>
        public const byte ScriptStepAck = 0x11;

        /// <summary>录制控制（手机 → PC）：{"on":true|false}</summary>
        public const byte RecordCtrl = 0x12;

        /// <summary>录制结果（PC → 手机）：{"ok","recording","name","script","err"}</summary>
        public const byte RecordResult = 0x13;

        /// <summary>
        /// 实时键鼠输入（手机 → PC，独立输入车道）：
        /// {"seq":1024,"ev":[{"t":"move","dx":3,"dy":-2},{"t":"down","b":1},{"t":"up","b":1},
        /// {"t":"wheel","d":2},{"t":"key","k":"CTRL+A"},{"t":"text","s":"中文"}]}
        /// </summary>
        public const byte LiveInput = 0x14;

        /// <summary>输入链路状态（PC → 手机，约 100ms 一次）：{"appliedSeq":1022,"rtt":0,"ok":1}</summary>
        public const byte InputState = 0x15;
    }

    public const byte FlagNeedAck = 0x01;

    public sealed record Frame(byte Type, byte[] Payload, bool NeedAck);

    // ---------- 编码 ----------

    public static void Write(Stream stream, Frame frame)
    {
        uint crc = frame.Payload.Length == 0
            ? 0xFFFF
            : Crc32(frame.Payload) & 0xFFFF;

        var head = new byte[HeaderSize];
        head[0] = 0xBD; head[1] = 0x54; head[2] = 1; head[3] = frame.Type;
        head[4] = (byte)(frame.NeedAck ? FlagNeedAck : 0);
        uint len = (uint)frame.Payload.Length;
        head[5] = (byte)(len >> 24); head[6] = (byte)(len >> 16);
        head[7] = (byte)(len >> 8); head[8] = (byte)len;
        head[9] = (byte)(crc >> 8); head[10] = (byte)crc;

        stream.Write(head, 0, HeaderSize);
        if (frame.Payload.Length > 0) stream.Write(frame.Payload, 0, frame.Payload.Length);
        stream.Flush();
    }

    /// <summary>读一帧；返回 null 表示流结束</summary>
    public static Frame? Read(Stream stream)
    {
        var head = new byte[HeaderSize];
        if (!ReadFully(stream, head)) return null;

        if (head[0] != 0xBD || head[1] != 0x54)
            throw new IOException("坏帧：MAGIC 不匹配");
        if (head[2] != 1)
            throw new IOException($"坏帧：协议版本不支持 v{head[2]}");

        byte type = head[3];
        bool needAck = (head[4] & FlagNeedAck) != 0;
        uint len = ((uint)head[5] << 24) | ((uint)head[6] << 16) | ((uint)head[7] << 8) | head[8];
        if (len > 16 * 1024 * 1024)
            throw new IOException($"坏帧：载荷长度异常 {len}");
        int crc = (head[9] << 8) | head[10];

        var payload = new byte[len];
        if (len > 0)
        {
            if (!ReadFully(stream, payload)) throw new IOException("连接在帧中间断开");
            if ((Crc32(payload) & 0xFFFF) != (uint)crc)
                throw new IOException("坏帧：CRC 校验失败");
        }
        return new Frame(type, payload, needAck);
    }

    private static bool ReadFully(Stream stream, byte[] buffer)
    {
        int off = 0;
        while (off < buffer.Length)
        {
            int n = stream.Read(buffer, off, buffer.Length - off);
            if (n <= 0) return off == 0 ? false : throw new IOException("连接在帧中间断开");
            off += n;
        }
        return true;
    }

    private static uint Crc32(byte[] data)
    {
        // 标准 CRC-32（与 java.util.zip.CRC32 一致）
        uint[] table = CrcTable.Value;
        uint crc = 0xFFFFFFFFu;
        foreach (byte b in data)
            crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }

    private static class CrcTable
    {
        public static readonly uint[] Value = Build();

        private static uint[] Build()
        {
            var t = new uint[256];
            for (uint i = 0; i < 256; i++)
            {
                uint c = i;
                for (int k = 0; k < 8; k++)
                    c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                t[i] = c;
            }
            return t;
        }
    }

    // ---------- 常用载荷 ----------

    public static Frame Hello(string machineName) =>
        new(FrameType.Hello, Encoding.UTF8.GetBytes(machineName), false);

    public static Frame Text(string content, bool needAck = true) =>
        new(FrameType.Text, Encoding.UTF8.GetBytes(content), needAck);

    public static Frame FileMeta(string json) =>
        new(FrameType.FileMeta, Encoding.UTF8.GetBytes(json), false);

    /// <summary>
    /// FILE_META 载荷：name 为 basename；path 为批次内相对路径（正斜杠）；batch 为批次 id。
    /// path/batch 为 null 时序列化成 null，旧版接收端只读 name/size，可安全忽略。
    /// </summary>
    public static Frame FileMeta(string name, long size, string? path = null, string? batch = null) =>
        new(FrameType.FileMeta,
            JsonSerializer.SerializeToUtf8Bytes(new { name, size, path, batch }), false);

    /// <summary>CONFIG：手机统一下发的传输上限，0 = 不限</summary>
    public static Frame Config(long maxBytes) =>
        new(FrameType.Config, JsonSerializer.SerializeToUtf8Bytes(new { maxBytes }), false);

    /// <summary>BATCH_META：文件夹批次元信息（files/bytes 为声明值，dirs 为相对路径列表）</summary>
    public static Frame BatchMeta(string id, string name, int files, long bytes,
        IReadOnlyList<string> dirs) =>
        new(FrameType.BatchMeta,
            JsonSerializer.SerializeToUtf8Bytes(new { id, name, files, bytes, dirs }), false);

    /// <summary>BATCH_END：批次结束（files 为实际发送的文件数）</summary>
    public static Frame BatchEnd(string id, int files) =>
        new(FrameType.BatchEnd, JsonSerializer.SerializeToUtf8Bytes(new { id, files }), false);

    public static Frame Error(string message) =>
        new(FrameType.Error, Encoding.UTF8.GetBytes(message), false);

    public static Frame Chunk(byte[] data, int offset, int length) =>
        new(FrameType.FileChunk, data[offset..(offset + length)], false);

    public static Frame FileEnd(bool needAck = true) =>
        new(FrameType.FileEnd, Array.Empty<byte>(), needAck);

    public static Frame Ack(byte ofType) =>
        new(FrameType.Ack, new[] { ofType }, false);

    public static Frame Pong() => new(FrameType.Pong, Array.Empty<byte>(), false);

    /// <summary>NET_INFO：手机下发的 TCP 数据通道端点</summary>
    public static Frame NetInfo(string json) =>
        new(FrameType.NetInfo, Encoding.UTF8.GetBytes(json), false);

    /// <summary>IDENT：PC 补报稳定标识（走 TCP 时用于把会话还原成同一台 PC）</summary>
    public static Frame Ident(string json) =>
        new(FrameType.Ident, Encoding.UTF8.GetBytes(json), false);

    /// <summary>AGENT_INFO：告诉手机本机可以代跑脚本步骤（本地注入）</summary>
    public static Frame AgentInfo(int script, string platform, bool unicode, bool secure,
        int input = 0, int text = 0) =>
        new(FrameType.AgentInfo,
            JsonSerializer.SerializeToUtf8Bytes(new
            {
                script,
                platform,
                unicode = unicode ? 1 : 0,
                secure = secure ? 1 : 0,
                input,
                text,
            }), false);

    /// <summary>INPUT_STATE：输入车道回执（已应用序号 + 注入是否成功）</summary>
    public static Frame InputState(long appliedSeq, int rtt, bool ok) =>
        new(FrameType.InputState,
            JsonSerializer.SerializeToUtf8Bytes(new
            {
                appliedSeq,
                rtt,
                ok = ok ? 1 : 0,
            }), false);

    /// <summary>SCRIPT_STEP_ACK：单个脚本步骤的执行结果</summary>
    public static Frame ScriptStepAck(string id, bool ok, string? err = null) =>
        new(FrameType.ScriptStepAck,
            JsonSerializer.SerializeToUtf8Bytes(new { id, ok, err }), false);

    /// <summary>
    /// RECORD_RESULT：录制状态 / 结果。
    /// 结束时 scriptJson 是整份脚本（嵌套对象，不是字符串），手机会直接解析导入。
    /// </summary>
    public static Frame RecordResult(bool ok, bool recording, string? name = null,
        string? scriptJson = null, string? err = null)
    {
        var node = new System.Text.Json.Nodes.JsonObject
        {
            ["ok"] = ok,
            ["recording"] = recording,
        };
        if (!string.IsNullOrEmpty(name)) node["name"] = name;
        if (!string.IsNullOrEmpty(err)) node["err"] = err;
        if (!string.IsNullOrEmpty(scriptJson))
            node["script"] = System.Text.Json.Nodes.JsonNode.Parse(scriptJson);

        return new Frame(FrameType.RecordResult, Encoding.UTF8.GetBytes(node.ToJsonString()), false);
    }
}
