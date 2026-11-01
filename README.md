<p align="center">
  <img src="icon.png" width="120" height="120" alt="BlueDesk 应用图标">
</p>

<h1 align="center">BlueDesk</h1>

<p align="center">
  <b>互传助手</b> · 三端辅助程序（Windows / Android / macOS）
</p>

<p align="center">
  <b>简体中文</b> | <a href="README.en.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a>
</p>

配合 BlueDesk 手机端「互传」页使用的三端辅助程序集合。
通过经典蓝牙 SPP 数据通道与手机通信，让 **A 电脑 → 手机 → B 电脑** 的文本与小文件互传
变成一次点击 —— 手机作为中转站，任一端都可以和手机互传，也可以借手机转发给另一台电脑。

> 数据通道与手机模拟键鼠的 HID 通道互相独立，同一套蓝牙配对即可同时使用。

本仓库包含三个平台各自的实现，它们共用同一套传输协议，因此 **可以混用**：
例如 Windows 发、macOS 收，或 Android 与 Windows 之间互传。

## 三端能力对照

| 能力 | Android | Windows | macOS |
|---|:---:|:---:|:---:|
| 发送文本 | ✓ 输入框 / 粘贴 / 接收其他 App 分享 | ✓ 剪贴板 | ✓ 剪贴板 |
| 发送单个文件 | ✓ | ✓ | ✓ |
| 发送整个文件夹 | ✓ 经 SAF 目录树 | ✓ `BATCH_*` 批量帧 | — |
| 接收文本 → 剪贴板 | ✓ 同时发通知 | ✓ 同时弹气泡 | ✓ 同时发通知 |
| 接收文件 | ✓ `Download/BlueDesk` | ✓ `Downloads\BlueDesk` | ✓ `~/Downloads/BlueDesk` |
| 接收文件夹 | ✓ | ✓ | — |
| 全局热键 | — | `Ctrl+Alt+B` / `Ctrl+Alt+F` | `Ctrl+Opt+B` / `Ctrl+Opt+F` |
| 系统集成 | 系统分享目标 | 资源管理器右键菜单 | Finder「服务」菜单 |
| 后台常驻 | 前台服务 + 开机自启 | 托盘 + `shell:startup` | 菜单栏 + 登录项 |
| 遵循手机下发的传输上限 | ✓ | ✓ | — 固定 64 MB |

`—` 表示该端暂未实现，不影响其他两端之间的互传。

## 各端速览

### Android

Kotlin + Jetpack Compose，前台服务常驻保持连接；可作为系统分享目标接收其他 App 的文字与文件，
也支持发送整个文件夹。

- **要求**：JDK 17、Android SDK 36（`minSdk 29` / `targetSdk 36`）
- **构建**：`cd BlueDeskRelayAndroid && ./gradlew assembleDebug`
  → 产物 `app/build/outputs/apk/debug/app-debug.apk`
- **源码**：`BlueDeskRelayAndroid/app/src/main/java/com/lingzhi/bluedesk/relayandroid/`

### Windows

.NET 8 WinForms 托盘程序，支持全局热键与资源管理器右键「发送到 BlueDesk」。

- **要求**：Windows 10 2004（build 19041）及以上、.NET 8 SDK
- **构建**：`cd BlueDeskRelayWindows && dotnet build -c Release`
  → 产物 `bin\Release\net8.0-windows10.0.19041.0\BlueDeskRelay.exe`
- **详见**：[BlueDeskRelayWindows/README.md](BlueDeskRelayWindows/README.md)
  （含 NuGet `NU1301` 构建踩坑、连接设备菜单说明）

### macOS

Swift + SwiftPM 菜单栏程序（`LSUIElement`），基于 IOBluetooth 的经典蓝牙 RFCOMM；
支持 Finder「服务」菜单与全局热键。

- **要求**：macOS 12+、Xcode Command Line Tools
- **构建**：`cd BlueDeskRelayMac && ./bundle.sh`
  → 产物 `BlueDesk Relay.app`
- **详见**：[BlueDeskRelayMac/README.md](BlueDeskRelayMac/README.md)

## 通信协议

三端实现逐字节对齐，协议定义分别位于
`RelayProtocol.kt`（Android）、`Protocol.cs`（Windows）、`Protocol.swift`（macOS）。

- **服务 UUID**：`a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1`
- **帧格式**：11 字节头（MAGIC / 版本 / 类型 / FLAGS / 长度 / CRC32 低 16 位）+ 载荷
- **帧类型**：`HELLO`、`TEXT`、`FILE_META`、`FILE_CHUNK`、`FILE_END`、`ACK`、`PING`、`PONG`、
  `ERROR`、`CONFIG`、`BATCH_META`、`BATCH_END`
- **分块**：文件按 4 KB 分块传输
- **传输上限**：默认 64 MB，由手机通过 `CONFIG` 帧统一下发（0 表示不限）
- **性能**：SPP 通道实测约 50~200 KB/s，适合文本与几 MB 以内的小文件

## 多语言

三端统一支持 **简体中文、English、日本語、한국어**，按系统语言自动切换，
未匹配的语言回退英文。

| 平台 | 文案位置 |
|---|---|
| Android | `app/src/main/res/values*/strings.xml`（默认英文 + `values-zh` / `-ja` / `-ko`） |
| Windows | `BlueDeskRelayWindows/Strings.cs`（四语内嵌，`CultureInfo.CurrentUICulture` 判定） |
| macOS | `Sources/BlueDeskRelayMac/Localization.swift`（UI 文案）<br>`Resources/<lang>.lproj/InfoPlist.strings`（系统权限弹窗、Finder 服务名） |

> 新增语言：三端各加一份对应资源即可；`Strings.cs` 的 `Get(zh, en, ja, ko)` 需扩参。
> 日志（`relay.log`、`NSLog`）刻意保持中文，便于对照代码排查，不属于 UI 文案。

本 README 本身也提供四语版本，切换链接在各文件顶部。

## 使用步骤（通用）

1. **配对**：在系统蓝牙设置里与手机（`BlueDesk-XXXXXX`）配对一次。
   配对同时会建立 HID（键鼠）与 SPP（数据）两个通道的凭据。
2. **手机端**：打开 BlueDesk → 底部「互传」Tab → 开启互传。
3. **电脑端**：启动对应平台的程序，它会自动发现已配对的 BlueDesk 手机并连接。
   若手机在系统里显示的是真实机型名（如 `S25U`、`SM-S9380`）而不是 `BlueDesk*`，
   自动发现可能找不到它 —— 用「连接设备」手动点选一次，之后会自动记住。
4. **互传**：电脑 A 发送 → 手机「互传」页出现记录 → 点「转发…」选择电脑 B
   → B 端自动写入剪贴板或落盘并弹出提示。

## 许可

[Apache License 2.0](LICENSE)
