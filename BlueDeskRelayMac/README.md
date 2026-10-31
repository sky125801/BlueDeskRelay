# BlueDesk 互传助手（macOS 端）

配合手机端 BlueDesk「互传」页使用的菜单栏程序。
通过经典蓝牙 RFCOMM（IOBluetooth）与手机通信，实现 **A 电脑 → 手机 → B 电脑** 的文本 / 小文件互传。

> 数据通道与手机模拟键鼠的 HID 通道互相独立，同一套蓝牙配对即可同时使用。

## 功能

- **发送**：菜单栏图标菜单发送剪贴板 / 文件（≤64MB），全局热键 `Ctrl+Opt+B` 发送剪贴板
- **Finder 右键发送**：选中文件 → 右键 →「服务 / 快速操作」→「发送到 BlueDesk」，直接交给手机
- **快捷键发送文件**：Finder 里选中文件后按 `Ctrl+Opt+F` 直接发送；
  前台不是 Finder 时，回退到 `Cmd+C` 复制到剪贴板的文件。首次使用会请求「自动化」权限
- **接收**：文本自动写入剪贴板（可直接 Cmd+V，中文原样）；文件保存到 `~/Downloads/BlueDesk`
- **手动连接**：菜单「连接设备 ▸」列出全部已配对设备，点选即连（当前连接打勾，
  记忆设备带 ★）；断线重连与重启后优先连记忆设备；「清除记忆」恢复自动发现
- **状态**：断线每 5 秒自动重连；连接 / 收发均有系统通知

## 构建要求

- macOS 12+，Xcode Command Line Tools（`xcode-select --install`）

```bash
cd BlueDeskRelayMac
./bundle.sh
# 产物：./BlueDesk Relay.app
```

只想出命令行可执行文件：`swift build -c release`（产物 `.build/release/BlueDeskRelayMac`）。

## 使用步骤

1. **配对**：系统设置 → 蓝牙，与手机（BlueDesk-XXXXXX）配对一次。
   配对同时建立 HID（键鼠）与 SPP（数据）两个通道的凭据。
2. **手机端**：打开 BlueDesk → 底部「互传」Tab → 开启互传。
3. **电脑端**：运行 `BlueDesk Relay.app`（首次弹出蓝牙/通知授权请允许）。
   菜单栏出现双向箭头图标，自动连接后菜单显示「已连接 BlueDesk-XXXXXX」。
   可把 .app 拖进「系统设置 → 通用 → 登录项」开机自启。
4. **互传**：
   - 电脑 A：`Ctrl+Opt+B` 或菜单发送剪贴板 → 手机「互传」页出现记录；
   - 电脑 A：Finder 里选中文件 → 右键「发送到 BlueDesk」，或按 `Ctrl+Opt+F` → 手机收到文件；
   - 手机：点该记录的「转发…」选择电脑 B → B 端自动写入剪贴板 / 落盘并弹通知。

> 右键菜单来自 `Info.plist` 的 `NSServices` 声明，macOS 会缓存服务列表：
> 首次把 `.app` 放到 `/Applications` 并运行一次后即可在 Finder 服务里看到；
> 若没出现，执行 `/System/Library/CoreServices/pbs -update` 或注销重新登录。

## 技术说明

- 蓝牙栈：IOBluetooth（经典蓝牙 RFCOMM 客户端）；CoreBluetooth 仅支持 BLE，无法用于本场景
- 服务 UUID：`a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1`（与手机端 `TransferProtocol.SERVICE_UUID` 一致）
- 帧格式：11 字节头（MAGIC/版本/类型/FLAGS/长度/CRC32低16位）+ 载荷，详见 `Protocol.swift`
  与手机端 `TransferProtocol.kt`、Windows 端 `Protocol.cs` 逐字节对齐；文件按 4KB 分块
- 注意：SPP 通道实测约 50~200 KB/s，适合文本与几 MB 以内的小文件

## 源码结构

```
Sources/BlueDeskRelayMac/
  main.swift          入口（NSApplication + accessory 策略）
  AppDelegate.swift   菜单栏 UI、热键、通知、剪贴板
  PhoneLink.swift     IOBluetooth RFCOMM 连接 / 收发 / 自动重连
  Protocol.swift      传输协议编解码（与手机端逐字节对齐）+ 文件组装器
```
