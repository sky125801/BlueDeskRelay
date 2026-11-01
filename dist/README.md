# BlueDesk Relay 0.0.1 安装包

| 平台 | 文件 | 说明 |
|---|---|---|
| Windows | `BlueDeskRelay-Windows-0.0.1.zip` | 解压后运行 `BlueDeskRelay.exe`。需安装 [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0)（x64），系统要求 Windows 10 2004 / build 19041 及以上 |
| Android | `BlueDeskRelay-Android-0.0.1.apk` | `minSdk 29` / `targetSdk 36`，versionCode 1，versionName 0.0.1。安装时需允许「安装未知来源应用」 |

两端共用同一套蓝牙 SPP 传输协议，可与 macOS 端混用。

> 注：0.0.1 的 APK 使用本地 debug 证书签名，仅用于测试安装；后续正式发布需换用固定的 release 签名证书，否则无法覆盖升级。
