# BlueDesk Relay

[简体中文](README.md) | **English** | [日本語](README.ja.md) | [한국어](README.ko.md)

A set of companion apps for the **Relay** page of the BlueDesk mobile app, for three platforms.
They talk to the phone over the classic Bluetooth SPP data channel, turning
**PC A → phone → PC B** transfer of text and small files into a single click. The phone acts
as a relay, so any endpoint can exchange content with it, and can also forward to another PC.

> The data channel is independent of the HID (keyboard/mouse) channel, so a single
> Bluetooth pairing serves both at the same time.

This repository holds one implementation per platform. They share the same wire protocol,
so they **interoperate freely** — Windows sending to macOS, or Android to Windows, both work.

## Capability matrix

| Capability | Android | Windows | macOS |
|---|:---:|:---:|:---:|
| Send text | ✓ input box / paste / receive shares from other apps | ✓ clipboard | ✓ clipboard |
| Send a single file | ✓ | ✓ | ✓ |
| Send a whole folder | ✓ via SAF tree | ✓ `BATCH_*` frames | — |
| Receive text → clipboard | ✓ plus a notification | ✓ plus a balloon | ✓ plus a notification |
| Receive files | ✓ `Download/BlueDesk` | ✓ `Downloads\BlueDesk` | ✓ `~/Downloads/BlueDesk` |
| Receive a folder | ✓ | ✓ | — |
| Global hotkey | — | `Ctrl+Alt+B` / `Ctrl+Alt+F` | `Ctrl+Opt+B` / `Ctrl+Opt+F` |
| OS integration | share target | Explorer context menu | Finder Services |
| Runs in the background | foreground service + boot start | tray + `shell:startup` | menu bar + login items |
| Honors the phone's transfer limit | ✓ | ✓ | — fixed at 64 MB |

`—` means the feature isn't implemented on that platform yet; transfers between the other
two still work.

## At a glance

### Android

Kotlin + Jetpack Compose, with a foreground service keeping the connection alive. It can act
as a system share target for text and files from other apps, and it can send whole folders.

- **Requirements**: JDK 17, Android SDK 36 (`minSdk 29` / `targetSdk 36`)
- **Build**: `cd BlueDeskRelayAndroid && ./gradlew assembleDebug`
  → `app/build/outputs/apk/debug/app-debug.apk`
- **Source**: `BlueDeskRelayAndroid/app/src/main/java/com/lingzhi/bluedesk/relayandroid/`

### Windows

A .NET 8 WinForms tray app with global hotkeys and an Explorer context menu entry
("Send to BlueDesk").

- **Requirements**: Windows 10 2004 (build 19041) or later, .NET 8 SDK
- **Build**: `cd BlueDeskRelayWindows && dotnet build -c Release`
  → `bin\Release\net8.0-windows10.0.19041.0\BlueDeskRelay.exe`
- **Details**: [BlueDeskRelayWindows/README.md](BlueDeskRelayWindows/README.md)
  (includes the NuGet `NU1301` build gotcha and the Connect Device menu)

### macOS

A Swift + SwiftPM menu bar app (`LSUIElement`) built on IOBluetooth classic RFCOMM,
with Finder Services support and global hotkeys.

- **Requirements**: macOS 12+, Xcode Command Line Tools
- **Build**: `cd BlueDeskRelayMac && ./bundle.sh`
  → `BlueDesk Relay.app`
- **Details**: [BlueDeskRelayMac/README.md](BlueDeskRelayMac/README.md)

## Wire protocol

All three implementations are byte-for-byte aligned. The protocol lives in
`RelayProtocol.kt` (Android), `Protocol.cs` (Windows) and `Protocol.swift` (macOS).

- **Service UUID**: `a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1`
- **Frame format**: 11-byte header (MAGIC / version / type / FLAGS / length / CRC32 low 16 bits)
  plus payload
- **Frame types**: `HELLO`, `TEXT`, `FILE_META`, `FILE_CHUNK`, `FILE_END`, `ACK`, `PING`, `PONG`,
  `ERROR`, `CONFIG`, `BATCH_META`, `BATCH_END`
- **Chunking**: files are split into 4 KB chunks
- **Transfer limit**: 64 MB by default, pushed from the phone via a `CONFIG` frame
  (0 means unlimited)
- **Throughput**: the SPP channel measures roughly 50–200 KB/s, suited to text and files of
  a few MB

## Languages

All three platforms support **简体中文, English, 日本語, 한국어**. The language follows the
system setting automatically; anything else falls back to English.

| Platform | Where the strings live |
|---|---|
| Android | `app/src/main/res/values*/strings.xml` (English default + `values-zh` / `-ja` / `-ko`) |
| Windows | `BlueDeskRelayWindows/Strings.cs` (four languages inline, picked via `CultureInfo.CurrentUICulture`) |
| macOS | `Sources/BlueDeskRelayMac/Localization.swift` (UI strings)<br>`Resources/<lang>.lproj/InfoPlist.strings` (system permission prompts, Finder service name) |

> Adding a language: add the matching resource file on each platform; `Strings.cs`'s
> `Get(zh, en, ja, ko)` needs one more argument.
> Logs (`relay.log`, `NSLog`) are intentionally kept in Chinese so they can be read alongside
> the source; they are not UI strings.

This README is also available in four languages — see the switcher at the top of each file.

## Usage (common to all platforms)

1. **Pair**: pair with the phone (`BlueDesk-XXXXXX`) once in your system Bluetooth settings.
   Pairing sets up credentials for both the HID (keyboard/mouse) and SPP (data) channels.
2. **Phone**: open BlueDesk → the "Relay" tab at the bottom → turn on Relay.
3. **PC**: start the app for your platform; it auto-discovers the paired BlueDesk phone and
   connects. If the phone shows up under its real model name (`S25U`, `SM-S9380`, …) instead
   of `BlueDesk*`, auto-discovery may miss it — pick it once under "Connect Device" and it will
   be remembered.
4. **Transfer**: PC A sends → a record appears on the phone's Relay page → tap "Forward…" and
   pick PC B → B writes the clipboard or saves the file and shows a prompt.

## License

[Apache License 2.0](LICENSE)
