using System.Runtime.InteropServices;
using System.Text.Json;

namespace BlueDeskRelay;

/// <summary>
/// 脚本录制器 —— 用全局低级钩子抓真实键鼠，生成与手机一致的脚本文件。
///
/// 产出格式（.json，与手机端 ScriptFileImporter 对应）：
/// {"format":"bluedesk-script","version":1,"name":"…","steps":[
///   {"t":"click","x":640,"y":360,"abs":true,"d":300}, …]}
///
/// 坐标统一换算成 1280×720 逻辑坐标；`d` 是距上一步的间隔毫秒。
/// 自身注入的输入（SendInput）带 LLKHF_INJECTED / LLMHF_INJECTED 标记，会被跳过，
/// 因此「边跑脚本边录制」不会录出一串自我回放。
/// </summary>
internal static class ScriptRecorder
{
    public static bool IsRecording { get; private set; }

    private const int LogicalWidth = 1280;
    private const int LogicalHeight = 720;
    private const int MaxSteps = 2_000;

    private const int WhKeyboardLl = 13;
    private const int WhMouseLl = 14;

    private const int WmKeyDown = 0x0100;
    private const int WmSysKeyDown = 0x0104;
    private const int WmMouseMove = 0x0200;
    private const int WmLButtonDown = 0x0201;
    private const int WmRButtonDown = 0x0204;
    private const int WmMouseWheel = 0x020A;

    private const uint LlkhfInjected = 0x10;
    private const uint LlmhfInjected = 0x01;

    private const int SmXVirtualScreen = 76;
    private const int SmYVirtualScreen = 77;
    private const int SmCxVirtualScreen = 78;
    private const int SmCyVirtualScreen = 79;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int nVirtKey);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
    }

    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern bool PostThreadMessage(uint idThread, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    // 委托必须用字段持有，否则会被 GC 回收，钩子回调直接崩进程
    private static HookProc? _keyboardProc;
    private static HookProc? _mouseProc;
    private static IntPtr _keyboardHook;
    private static IntPtr _mouseHook;

    // 低级钩子只在安装它的线程上回调，该线程必须有消息循环 —— 所以录制器自带一个
    private static Thread? _hookThread;
    private static uint _hookThreadId;

    private sealed class RecStep
    {
        public string T = "";
        public int? X;
        public int? Y;
        public int? W;
        public string? K;
        public long D;
        public bool Abs;
    }

    private static readonly List<RecStep> Steps = new();
    private static readonly HashSet<uint> HeldKeys = new();
    private static readonly object Gate = new();

    private static long _lastAt;
    private static long _lastMoveAt;
    private static long _lastClickAt;

    /// <summary>开始录制；钩子安装失败返回 false</summary>
    public static bool Start()
    {
        if (IsRecording) return true;

        lock (Gate)
        {
            Steps.Clear();
            HeldKeys.Clear();
            _lastAt = Environment.TickCount64;
            _lastMoveAt = 0;
            _lastClickAt = 0;
        }

        using var ready = new ManualResetEventSlim(false);
        _hookThread = new Thread(() =>
        {
            _keyboardProc = KeyboardHook;
            _mouseProc = MouseHook;
            var module = GetModuleHandle(null);
            _keyboardHook = SetWindowsHookEx(WhKeyboardLl, _keyboardProc, module, 0);
            _mouseHook = SetWindowsHookEx(WhMouseLl, _mouseProc, module, 0);

            if (_keyboardHook == IntPtr.Zero || _mouseHook == IntPtr.Zero)
            {
                StopHooks();
                ready.Set();
                return;
            }

            _hookThreadId = GetCurrentThreadId();
            ready.Set();

            // 钩子回调由这条消息循环派发；Stop() 用 WM_QUIT 让它退出
            while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
            StopHooks();
        })
        {
            IsBackground = true,
            Name = "BlueDeskScriptRecorder",
        };
        _hookThread.SetApartmentState(ApartmentState.STA);
        _hookThread.Start();

        ready.Wait(2_000);
        var ok = _keyboardHook != IntPtr.Zero && _mouseHook != IntPtr.Zero;
        IsRecording = ok;
        return ok;
    }

    /// <summary>录制结果：脚本 JSON + 展示名 + 本地备份路径</summary>
    public sealed record RecordResult(string Name, string ScriptJson, string FilePath, int Steps);

    /// <summary>结束录制并返回脚本；没有录到步骤返回 null</summary>
    public static RecordResult? Stop()
    {
        if (!IsRecording) return null;
        IsRecording = false;

        // 让钩子线程的消息循环退出并自行卸载钩子
        if (_hookThreadId != 0)
        {
            PostThreadMessage(_hookThreadId, 0x0012 /* WM_QUIT */, IntPtr.Zero, IntPtr.Zero);
        }
        _hookThread?.Join(1_500);
        if (_keyboardHook != IntPtr.Zero || _mouseHook != IntPtr.Zero)
        {
            // 线程没在预期时间内退出时兜底卸载
            StopHooks();
        }
        _hookThread = null;
        _hookThreadId = 0;

        List<RecStep> snapshot;
        lock (Gate)
        {
            snapshot = Steps.ToList();
        }
        if (snapshot.Count == 0) return null;

        var name = $"录制 {DateTime.Now:yyyy-MM-dd HH:mm}";
        var payload = new Dictionary<string, object?>
        {
            ["format"] = "bluedesk-script",
            ["version"] = 1,
            ["name"] = name,
            ["steps"] = snapshot.Select(s =>
            {
                var d = new Dictionary<string, object?> { ["t"] = s.T, ["d"] = s.D };
                if (s.X.HasValue) d["x"] = s.X.Value;
                if (s.Y.HasValue) d["y"] = s.Y.Value;
                if (s.W.HasValue) d["w"] = s.W.Value;
                if (!string.IsNullOrEmpty(s.K)) d["k"] = s.K;
                if (s.Abs) d["abs"] = true;
                return d;
            }).ToList(),
        };

        var options = new JsonSerializerOptions { WriteIndented = true };
        var json = JsonSerializer.Serialize(payload, options);

        // 本地再留一份备份，方便没有连接手机时找回
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "BlueDesk");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, $"record-{DateTime.Now:yyyyMMdd-HHmmss}.json");
        File.WriteAllText(path, json);

        return new RecordResult(name, json, path, snapshot.Count);
    }

    private static void StopHooks()
    {
        if (_keyboardHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_keyboardHook);
            _keyboardHook = IntPtr.Zero;
        }
        if (_mouseHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_mouseHook);
            _mouseHook = IntPtr.Zero;
        }
        _keyboardProc = null;
        _mouseProc = null;
    }

    // ---------- 钩子 ----------

    private static IntPtr KeyboardHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && IsRecording)
        {
            var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            var message = wParam.ToInt32();
            if ((info.flags & LlkhfInjected) == 0)
            {
                if (message == WmKeyDown || message == WmSysKeyDown) OnKeyDown(info.vkCode);
                else OnKeyUp(info.vkCode);
            }
        }
        return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    private static IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && IsRecording)
        {
            var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
            if ((info.flags & LlmhfInjected) == 0)
            {
                var message = wParam.ToInt32();
                var (lx, ly) = ToLogical(info.pt.x, info.pt.y);
                switch (message)
                {
                    case WmMouseMove:
                        OnMouseMove(lx, ly);
                        break;
                    case WmLButtonDown:
                        OnMouseDown(lx, ly, "click");
                        break;
                    case WmRButtonDown:
                        OnMouseDown(lx, ly, "rclick");
                        break;
                    case WmMouseWheel:
                        var delta = (short)((info.mouseData >> 16) & 0xFFFF);
                        OnWheel(lx, ly, delta / 120);
                        break;
                }
            }
        }
        return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    // ---------- 记录 ----------

    private static void OnMouseMove(int x, int y)
    {
        var now = Environment.TickCount64;
        // 轨迹按 40ms 采样：既保留移动路径，又不至于一条轨迹录出上万个点
        if (now - _lastMoveAt < 40) return;
        _lastMoveAt = now;
        Add(new RecStep { T = "move", X = x, Y = y, Abs = true });
    }

    private static void OnMouseDown(int x, int y, string type)
    {
        var now = Environment.TickCount64;
        lock (Gate)
        {
            // 300ms 内同位置的第二次左键 → 合并成双击
            if (type == "click" && Steps.Count > 0)
            {
                var last = Steps[^1];
                if (last.T == "click" && now - _lastClickAt < 300 &&
                    Math.Abs((last.X ?? 0) - x) <= 6 && Math.Abs((last.Y ?? 0) - y) <= 6)
                {
                    last.T = "dclick";
                    last.D += now - _lastAt;
                    _lastAt = now;
                    _lastClickAt = 0;
                    return;
                }
            }
            _lastClickAt = now;
        }
        Add(new RecStep { T = type, X = x, Y = y, Abs = true });
    }

    private static void OnWheel(int x, int y, int steps)
    {
        if (steps == 0) return;
        Add(new RecStep { T = "wheel", X = x, Y = y, W = steps });
    }

    private static void OnKeyDown(uint vk)
    {
        if (IsModifier(vk)) return;
        // 按住不放会持续触发 KeyDown，这里只认第一次
        if (!HeldKeys.Add(vk)) return;

        var token = KeyToken(vk);
        if (token == null) return;

        var parts = new List<string>();
        if (IsDown(0x11)) parts.Add("CTRL");
        if (IsDown(0x12)) parts.Add("ALT");
        if (IsDown(0x10)) parts.Add("SHIFT");
        if (IsDown(0x5B)) parts.Add("WIN");
        parts.Add(token);

        Add(new RecStep
        {
            T = parts.Count > 1 ? "combo" : "key",
            K = string.Join("+", parts),
        });
    }

    private static void OnKeyUp(uint vk) => HeldKeys.Remove(vk);

    private static void Add(RecStep step)
    {
        lock (Gate)
        {
            if (Steps.Count >= MaxSteps) return;
            var now = Environment.TickCount64;
            step.D = Math.Clamp(now - _lastAt, 1, 30_000);
            _lastAt = now;
            Steps.Add(step);
        }
    }

    private static bool IsDown(int vk) => (GetKeyState(vk) & 0x8000) != 0;

    private static bool IsModifier(uint vk) => vk is 0x10 or 0x11 or 0x12 or 0x5B or 0x5C
        or (>= 0xA0 and <= 0xA5);

    private static string? KeyToken(uint vk)
    {
        if (vk is >= 0x41 and <= 0x5A) return ((char)vk).ToString();
        if (vk is >= 0x30 and <= 0x39) return ((char)vk).ToString();
        if (vk is >= 0x70 and <= 0x87) return $"F{vk - 0x6F}";
        return vk switch
        {
            0x0D => "ENTER",
            0x09 => "TAB",
            0x1B => "ESC",
            0x20 => "SPACE",
            0x08 => "BACKSPACE",
            0x2E => "DELETE",
            0x2D => "INSERT",
            0x24 => "HOME",
            0x23 => "END",
            0x21 => "PAGEUP",
            0x22 => "PAGEDOWN",
            0x26 => "UP",
            0x28 => "DOWN",
            0x25 => "LEFT",
            0x27 => "RIGHT",
            0x14 => "CAPSLOCK",
            0x2C => "PRINTSCREEN",
            _ => null,
        };
    }

    private static (int, int) ToLogical(int sx, int sy)
    {
        var vx = GetSystemMetrics(SmXVirtualScreen);
        var vy = GetSystemMetrics(SmYVirtualScreen);
        var vw = Math.Max(1, GetSystemMetrics(SmCxVirtualScreen));
        var vh = Math.Max(1, GetSystemMetrics(SmCyVirtualScreen));

        var lx = (int)Math.Round((sx - vx) * (double)LogicalWidth / vw);
        var ly = (int)Math.Round((sy - vy) * (double)LogicalHeight / vh);
        return (Math.Clamp(lx, 0, LogicalWidth - 1), Math.Clamp(ly, 0, LogicalHeight - 1));
    }
}
