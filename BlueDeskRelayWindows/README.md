# BlueDesk 互传助手（Windows 端）

配合手机端 BlueDesk「互传」页使用的 Windows 托盘程序。
通过经典蓝牙 SPP 数据通道与手机通信，实现 **A 电脑 → 手机 → B 电脑** 的文本 / 小文件互传。

> 数据通道与手机模拟键鼠的 HID 通道互相独立，同一套蓝牙配对即可同时使用。

三端总览与能力对照见[仓库根 README](../README.md)。

## 功能

- **发送**：托盘右键菜单发送剪贴板 / 文件（≤64MB），或全局热键 `Ctrl+Alt+B` 发送剪贴板
- **资源管理器右键发送**：选中文件 → 右键 →「发送到 BlueDesk」，直接交给手机；
  程序未运行时会被自动拉起，连上手机后补发（HKCU 注册，无需管理员权限）
- **快捷键发送文件**：在资源管理器选中文件后按 `Ctrl+Alt+F` 直接发送；
  前台不是资源管理器时，回退到剪切板里 `Ctrl+C` 复制的文件
- **发送文件夹**：托盘菜单「发送文件夹…」，整批经 `BATCH_META` / `FILE_*` / `BATCH_END` 传输
- **接收**：文本自动写入剪贴板（可直接 Ctrl+V，中文原样）；文件保存到 `Downloads\BlueDesk`
- **手动连接**：菜单「连接设备 ▸」列出全部已配对设备，点选即连（当前连接打勾、
  记忆设备带 ★）；断线重连与重启后优先连记忆设备；「清除记忆」恢复自动发现
- **状态**：断线自动重连（每 5s），连接 / 收发均有气泡通知

## 构建要求

- Windows 10 2004（build 19041）及以上 / Windows 11
  —— 因为要用 WinRT 枚举已配对设备，TFM 为 `net8.0-windows10.0.19041.0`
- .NET 8 SDK（`winget install Microsoft.DotNet.SDK.8`）

```powershell
cd BlueDeskRelayWindows
dotnet build -c Release
# 产物：bin\Release\net8.0-windows10.0.19041.0\BlueDeskRelay.exe
```

如需单文件发布：

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true
# 产物：bin\Release\net8.0-windows10.0.19041.0\win-x64\publish\BlueDeskRelay.exe
```

### 构建踩坑：NuGet 本地源不存在（NU1301）

如果 `dotnet restore` 报：

```
error NU1301: 本地源“d:\Program Files (x86)\Microsoft Visual Studio\Shared\NuGetPackages”不存在
```

这是**本机 Visual Studio 的全局配置过期**，不是项目问题。来源：
`C:\Program Files (x86)\NuGet\Config\Microsoft.VisualStudio.FallbackLocation.config`
里声明了一个指向 D 盘的 `fallbackPackageFolders`，而这台机器没有 D 盘。

项目里已放好根目录的 `nuget.config`，在本目录下构建会自动清空继承的 fallback 目录，
无需管理员权限、不改动系统配置。

注意它**只对本仓库目录下的工程生效**。在别处新建 .NET 工程仍会报同样的错，
那时要么把 `nuget.config` 复制过去，要么用管理员权限修正上面那个全局配置文件。

## 使用步骤

1. **配对**：Windows 设置 → 蓝牙 → 添加设备，与手机（BlueDesk-XXXXXX）配对一次即可。
   配对同时会建立 HID（键鼠）与 SPP（数据）两个通道的凭据。
2. **手机端**：打开 BlueDesk → 底部「互传」Tab → 开启互传。
3. **电脑端**：启动 `BlueDeskRelay.exe`（可放 `shell:startup` 开机自启）。
   程序自动发现已配对的 BlueDesk 手机并连接，托盘显示「已连接」。
   - 若手机在系统里显示的是真实机型名（如 `S25U`、`SM-S9380`）而不是 `BlueDesk*`，
     自动发现找不到它，请用托盘菜单 **连接设备 ▸** 手动点选一次，之后会自动记住。
4. **互传**：
   - 电脑 A：`Ctrl+Alt+B` 或托盘菜单发送剪贴板 → 手机「互传」页出现记录；
   - 手机：点该记录的「转发…」选择电脑 B → B 端自动写入剪贴板 / 落盘并弹气泡。

## 连接设备菜单说明

| 元素 | 含义 |
|---|---|
| ✓ 勾选 | 当前正在连接的设备 |
| ★ 名称（记忆） | 未连接时的记忆设备，重连与重启后优先连它 |
| 刷新设备列表 | 重新读取系统配对列表（刚配对完新设备时用） |
| 清除记忆 | 忘掉记忆设备，恢复自动发现第一台 `BlueDesk*` |

记忆地址保存在 `%APPDATA%\BlueDesk\relay.json`。缓存地址后重连是直连（1 秒内），
不必每次做十几秒的蓝牙查询；地址失效（换机 / 取消配对）时会自动回退到设备发现。

## 技术说明

- 蓝牙栈：[32feet.NET](https://github.com/inthehand/32feet)（NuGet `InTheHand.Net.Bluetooth` 4.1.40）
  —— 固定 4.1.40，**不要升 4.1.44**：该版本改了 `BluetoothClient.DiscoverDevices` 的重载，会编译失败
- 设备枚举：WinRT `DeviceInformation.FindAllAsync` 读系统配对缓存（约 300ms，不触发射频查询）；
  32feet 的 `DiscoverDevices` 只有单参重载，每次都要做完整 inquiry（10~20 秒），不能用于菜单
- 服务 UUID：`a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1`（与手机端 `TransferProtocol.SERVICE_UUID` 一致）
- 帧格式：11 字节头（MAGIC/版本/类型/FLAGS/长度/CRC32低16位）+ 载荷，详见 `Protocol.cs`
  与手机端 `TransferProtocol.kt` 逐字节对齐；文件按 4KB 分块
- 注意：SPP 通道实测约 50~200 KB/s，适合文本与几 MB 以内的小文件

## 源码结构

```
BlueDeskRelayWindows/
  RelayApp.cs        托盘 UI、热键、剪贴板、连接设备菜单
  PhoneLink.cs       RFCOMM 连接 / 收发 / 断线重连守护
  Protocol.cs        传输协议编解码（与手机端逐字节对齐）
  PairedDevices.cs   已配对设备枚举（WinRT）
  RelaySettings.cs   记忆设备地址与传输上限（%APPDATA%\BlueDesk\relay.json）
  RelayLog.cs        运行日志（%APPDATA%\BlueDesk\relay.log）
  Strings.cs         四语文案表（zh / en / ja / ko）
```
