using System.Text;

namespace BlueDeskRelay;

/// <summary>
/// 极简运行日志：%APPDATA%\BlueDesk\relay.log
///
/// 托盘程序没有控制台，出问题时（连不上、收到内容却没反应、文件存不下）
/// 用户只能描述现象。这里把关键事件落成文本，排查时直接看最后几行即可。
///
/// 只保留最近约 200KB：超出就把旧文件轮转成 relay.old.log，避免无限增长。
/// </summary>
internal static class RelayLog
{
    private const long MaxBytes = 200 * 1024;

    private static readonly object Gate = new();

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "BlueDesk", "relay.log");

    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                var path = FilePath;
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);

                var info = new FileInfo(path);
                if (info.Exists && info.Length > MaxBytes)
                {
                    var old = Path.ChangeExtension(path, ".old.log");
                    File.Delete(old);
                    File.Move(path, old);
                }

                var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}  {message}{Environment.NewLine}";
                File.AppendAllText(path, line, Encoding.UTF8);
            }
        }
        catch
        {
            // 日志失败不能影响主流程
        }
    }
}
