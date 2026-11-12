using System.Runtime.InteropServices;
using System.Text.Json;

namespace BlueDeskRelay;

/// <summary>
/// 脚本步骤执行器 —— 手机把步骤下发过来后，由本机用 SendInput 直接注入。
///
/// 与 HID 通道相比：
///   - 鼠标按屏幕绝对坐标定位，不依赖相对位移累积与归零校准；
///   - 文本走 Unicode 注入，中文 / emoji / 任意字符都不受键盘布局与输入法限制；
///   - 每步返回真实执行结果，手机端据此判断成功或失败。
///
/// 坐标约定与手机一致：脚本里是 1280×720 逻辑坐标，这里按比例映射到虚拟桌面。
/// 注入失败会抛异常，由调用方回 SCRIPT_STEP_ACK 的 err 字段。
/// </summary>
internal static class ScriptRunner
{
    private const int LogicalWidth = 1280;
    private const int LogicalHeight = 720;

    /// <summary>步骤串行执行：手机虽然逐步等 ACK，但断线重连时可能有残留帧</summary>
    private static readonly object Gate = new();

    // ---------- Win32 ----------

    private const int InputMouse = 0;
    private const int InputKeyboard = 1;

    private const uint MouseMove = 0x0001;
    private const uint MouseLeftDown = 0x0002;
    private const uint MouseLeftUp = 0x0004;
    private const uint MouseRightDown = 0x0008;
    private const uint MouseRightUp = 0x0010;
    private const uint MouseMiddleDown = 0x0020;
    private const uint MouseMiddleUp = 0x0040;
    private const uint MouseWheel = 0x0800;
    private const uint MouseAbsolute = 0x8000;
    private const uint MouseVirtualDesk = 0x4000;

    private const uint KeyUp = 0x0002;
    private const uint KeyExtended = 0x0001;
    private const uint KeyUnicode = 0x0004;

    private const int SmXVirtualScreen = 76;
    private const int SmYVirtualScreen = 77;
    private const int SmCxVirtualScreen = 78;
    private const int SmCyVirtualScreen = 79;

    private const ushort VkReturn = 0x0D;
    private const ushort VkShift = 0x10;
    private const ushort VkControl = 0x11;
    private const ushort VkMenu = 0x12;
    private const ushort VkLWin = 0x5B;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    // ---------- 对外入口 ----------

    /// <summary>执行一条 SCRIPT_STEP 载荷；失败抛异常，消息直接回给手机</summary>
    public static void Execute(JsonElement step)
    {
        var type = GetString(step, "t") ?? "";
        lock (Gate)
        {
            switch (type)
            {
                case "move":
                    MoveTo(GetInt(step, "x"), GetInt(step, "y"));
                    break;

                case "click":
                    MoveTo(GetInt(step, "x"), GetInt(step, "y"));
                    Thread.Sleep(20);
                    MouseClick(MouseLeftDown, MouseLeftUp);
                    break;

                case "rclick":
                    MoveTo(GetInt(step, "x"), GetInt(step, "y"));
                    Thread.Sleep(20);
                    MouseClick(MouseRightDown, MouseRightUp);
                    break;

                case "dclick":
                    MoveTo(GetInt(step, "x"), GetInt(step, "y"));
                    Thread.Sleep(20);
                    MouseClick(MouseLeftDown, MouseLeftUp);
                    Thread.Sleep(40);
                    MouseClick(MouseLeftDown, MouseLeftUp);
                    break;

                case "wheel":
                    Scroll(GetInt(step, "w", 5));
                    break;

                case "key":
                case "combo":
                    KeyCombo(GetString(step, "k") ?? "");
                    break;

                case "type":
                    TypeText(GetString(step, "txt") ?? "");
                    break;

                case "wait":
                case "loop":
                case "end":
                    break;

                default:
                    throw new InvalidOperationException($"未知步骤类型「{type}」");
            }
        }
    }

    // ---------- 鼠标 ----------

    private static void MoveTo(int x, int y)
    {
        var vx = GetSystemMetrics(SmXVirtualScreen);
        var vy = GetSystemMetrics(SmYVirtualScreen);
        var vw = Math.Max(1, GetSystemMetrics(SmCxVirtualScreen));
        var vh = Math.Max(1, GetSystemMetrics(SmCyVirtualScreen));

        // 逻辑坐标 → 虚拟桌面像素 → 0..65535 归一化（SendInput 的绝对坐标约定）
        var px = vx + (double)x / LogicalWidth * vw;
        var py = vy + (double)y / LogicalHeight * vh;
        var nx = (int)Math.Round((px - vx) * 65535.0 / Math.Max(1, vw - 1));
        var ny = (int)Math.Round((py - vy) * 65535.0 / Math.Max(1, vh - 1));

        SendMouse(nx, ny, 0, MouseMove | MouseAbsolute | MouseVirtualDesk);
    }

    private static void MouseClick(uint downFlag, uint upFlag)
    {
        SendMouse(0, 0, 0, downFlag);
        Thread.Sleep(15);
        SendMouse(0, 0, 0, upFlag);
    }

    private static void Scroll(int amount)
    {
        if (amount == 0) return;
        // 一格 = 120；正数向上，与 HID 滚轮语义一致
        SendMouse(0, 0, unchecked((uint)(amount * 120)), MouseWheel);
    }

    private static void SendMouse(int dx, int dy, uint data, uint flags)
    {
        var input = new INPUT
        {
            type = InputMouse,
            U = new InputUnion
            {
                mi = new MOUSEINPUT
                {
                    dx = dx,
                    dy = dy,
                    mouseData = data,
                    dwFlags = flags,
                },
            },
        };
        Send(new[] { input });
    }

    // ---------- 键盘 ----------

    private static void TypeText(string text)
    {
        foreach (var ch in text)
        {
            if (ch == '\r') continue;
            if (ch == '\n')
            {
                TapKey(VkReturn, extended: false);
                continue;
            }
            // Unicode 注入按 UTF-16 单元发送，代理对（emoji）自然拆成两个单元
            SendUnicode(ch, up: false);
            SendUnicode(ch, up: true);
        }
    }

    private static void KeyCombo(string combo)
    {
        if (string.IsNullOrWhiteSpace(combo)) return;

        var parts = combo.Split('+', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Trim())
            .Where(p => p.Length > 0)
            .ToList();
        if (parts.Count == 0) return;

        var modifiers = new List<ushort>();
        for (var i = 0; i < parts.Count - 1; i++)
        {
            var vk = ModifierCode(parts[i])
                ?? throw new InvalidOperationException($"无法识别的修饰键「{parts[i]}」");
            modifiers.Add(vk);
        }

        var main = KeyCode(parts[^1])
            ?? throw new InvalidOperationException($"无法识别的按键「{parts[^1]}」");

        var extended = IsExtended(main);
        foreach (var m in modifiers) SendKey(m, up: false, extended: IsExtended(m));
        SendKey(main, up: false, extended: extended);
        Thread.Sleep(15);
        SendKey(main, up: true, extended: extended);
        for (var i = modifiers.Count - 1; i >= 0; i--)
            SendKey(modifiers[i], up: true, extended: IsExtended(modifiers[i]));
    }

    private static void TapKey(ushort vk, bool extended)
    {
        SendKey(vk, up: false, extended: extended);
        Thread.Sleep(15);
        SendKey(vk, up: true, extended: extended);
    }

    private static void SendKey(ushort vk, bool up, bool extended)
    {
        var flags = (up ? KeyUp : 0) | (extended ? KeyExtended : 0);
        var input = new INPUT
        {
            type = InputKeyboard,
            U = new InputUnion
            {
                ki = new KEYBDINPUT { wVk = vk, wScan = 0, dwFlags = flags },
            },
        };
        Send(new[] { input });
    }

    private static void SendUnicode(char ch, bool up)
    {
        var flags = KeyUnicode | (up ? KeyUp : 0);
        var input = new INPUT
        {
            type = InputKeyboard,
            U = new InputUnion
            {
                ki = new KEYBDINPUT { wVk = 0, wScan = ch, dwFlags = flags },
            },
        };
        Send(new[] { input });
    }

    private static bool IsExtended(ushort vk) => vk is
        0x21 or 0x22 or 0x23 or 0x24 or 0x25 or 0x26 or 0x27 or 0x28 or // 导航键
        0x2D or 0x2E or // Insert / Delete
        0x5B or 0x5C or // Win
        0xA3 or 0xA5;   // 右 Ctrl / 右 Alt

    private static ushort? ModifierCode(string token) => token.ToUpperInvariant() switch
    {
        "CTRL" or "CONTROL" => VkControl,
        "ALT" or "OPTION" => VkMenu,
        "SHIFT" => VkShift,
        "WIN" or "WINDOWS" or "CMD" or "COMMAND" => VkLWin,
        _ => null,
    };

    private static ushort? KeyCode(string token)
    {
        var t = token.Trim();
        if (t.Length == 1)
        {
            var ch = char.ToUpperInvariant(t[0]);
            if (ch is >= 'A' and <= 'Z') return ch;
            if (ch is >= '0' and <= '9') return ch;
            return t[0] switch
            {
                ' ' => (ushort)0x20,
                '-' => (ushort)0xBD,
                '=' => (ushort)0xBB,
                '[' => (ushort)0xDB,
                ']' => (ushort)0xDD,
                '\\' => (ushort)0xDC,
                ';' => (ushort)0xBA,
                '\'' => (ushort)0xDE,
                ',' => (ushort)0xBC,
                '.' => (ushort)0xBE,
                '/' => (ushort)0xBF,
                '`' => (ushort)0xC0,
                _ => (ushort?)null,
            };
        }

        return t.ToUpperInvariant() switch
        {
            "ENTER" or "RETURN" => (ushort)0x0D,
            "TAB" => (ushort)0x09,
            "ESC" or "ESCAPE" => (ushort)0x1B,
            "SPACE" => (ushort)0x20,
            "BACKSPACE" or "BKSP" => (ushort)0x08,
            "DELETE" or "DEL" => (ushort)0x2E,
            "INSERT" or "INS" => (ushort)0x2D,
            "HOME" => (ushort)0x24,
            "END" => (ushort)0x23,
            "PAGEUP" or "PGUP" => (ushort)0x21,
            "PAGEDOWN" or "PGDN" => (ushort)0x22,
            "UP" => (ushort)0x26,
            "DOWN" => (ushort)0x28,
            "LEFT" => (ushort)0x25,
            "RIGHT" => (ushort)0x27,
            "CAPSLOCK" or "CAPS" => (ushort)0x14,
            "PRINTSCREEN" or "PRTSC" => (ushort)0x2C,
            "PAUSE" => (ushort)0x13,
            _ => FunctionKey(t),
        };
    }

    private static ushort? FunctionKey(string token)
    {
        if (!token.StartsWith("F", StringComparison.OrdinalIgnoreCase)) return null;
        if (!int.TryParse(token[1..], out var n) || n < 1 || n > 24) return null;
        // F1..F24 恰好是连续的虚拟键码
        return (ushort)(0x70 + n - 1);
    }

    // ---------- 工具 ----------

    private static void Send(INPUT[] inputs)
    {
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != inputs.Length)
            throw new InvalidOperationException($"输入注入被系统拒绝（错误码 {Marshal.GetLastWin32Error()}）");
    }

    // ---------- 实时输入（Wi-Fi 输入车道） ----------
    //
    // 与脚本共用同一套注入原语：录制/回放与手机实时控制看到的坐标、按键语义完全一致。
    // 区别只在于实时输入不逐条回 ACK，靠序号覆盖：移动可丢，点击/按键按顺序立即执行。

    /// <summary>应用一批实时输入，返回（批次序号, 是否全部注入成功）</summary>
    internal static (long Seq, bool Ok) ApplyLive(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var seq = root.TryGetProperty("seq", out var s) ? s.GetInt64() : 0;
        var ok = true;
        if (!root.TryGetProperty("ev", out var list)) return (seq, ok);

        foreach (var ev in list.EnumerateArray())
        {
            var type = GetString(ev, "t");
            try
            {
                switch (type)
                {
                    case "move":
                        SendMouse(GetInt(ev, "dx"), GetInt(ev, "dy"), 0, MouseMove);
                        break;
                    case "down":
                    case "up":
                        var down = type == "down";
                        var right = ev.TryGetProperty("b", out var b) && b.GetInt32() == 2;
                        SendMouse(0, 0, 0, right
                            ? (down ? MouseRightDown : MouseRightUp)
                            : (down ? MouseLeftDown : MouseLeftUp));
                        break;
                    case "wheel":
                        Scroll(GetInt(ev, "d"));
                        break;
                    case "key":
                        KeyCombo(GetString(ev, "k") ?? "");
                        break;
                    case "text":
                        TypeText(GetString(ev, "s") ?? "");
                        break;
                }
            }
            catch (Exception ex)
            {
                // 提权窗口等场景系统会拒绝注入：标记失败，让手机自动回落 HID
                ok = false;
                RelayLog.Write($"实时输入注入失败（{type}）：{ex.Message}");
            }
        }
        return (seq, ok);
    }

    private static string? GetString(JsonElement step, string name) =>
        step.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString()
            : null;

    private static int GetInt(JsonElement step, string name, int fallback = 0)
    {
        if (!step.TryGetProperty(name, out var v)) return fallback;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n)) return n;
        if (v.ValueKind == JsonValueKind.String && int.TryParse(v.GetString(), out var s)) return s;
        return fallback;
    }
}
