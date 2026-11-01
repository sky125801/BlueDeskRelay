# BlueDesk Relay (Windows)

[简体中文](README.md) | **English** | [日本語](README.ja.md) | [한국어](README.ko.md)

A Windows tray app that pairs with the **Relay** page of the BlueDesk mobile app.
It talks to the phone over the classic Bluetooth SPP data channel, enabling
**PC A → phone → PC B** transfer of text and small files.

> The data channel is independent of the HID (keyboard/mouse) channel, so a single
> Bluetooth pairing serves both at the same time.

## Features

- **Send**: right-click the tray icon to send the clipboard or a file (≤64 MB),
  or press the global hotkey `Ctrl+Alt+B` to send the clipboard
- **Send from the Explorer context menu**: select files → right-click → "Send to BlueDesk"
  hands them straight to the phone. The app is launched automatically when it isn't running
  and sends once connected (registered under HKCU, no admin rights required)
- **Send with a hotkey**: select files in Explorer and press `Ctrl+Alt+F`.
  When Explorer isn't in the foreground it falls back to files copied with `Ctrl+C`
- **Receive**: text is written to the clipboard automatically (just press `Ctrl+V`,
  Chinese text preserved); files are saved to `Downloads\BlueDesk`
- **Manual connect**: the "Connect Device ▸" menu lists every paired device — click to connect
  (the active device is checked, the remembered one is marked ★). Reconnects and restarts
  prefer the remembered device; "Clear preferred" returns to auto-discovery
- **Status**: automatic reconnect after a disconnect (every 5 s); balloon notifications
  for connections and transfers

## Languages

All three platforms (Android / Windows / macOS) support **简体中文, English, 日本語, 한국어**.
The language follows the system setting automatically; anything else falls back to English.

| Platform | Where the strings live |
|---|---|
| Windows | `BlueDeskRelayWindows/Strings.cs` (four languages inline, picked via `CultureInfo.CurrentUICulture`) |
| Android | `app/src/main/res/values*/strings.xml` (English default + `values-zh` / `-ja` / `-ko`) |
| macOS | `Sources/BlueDeskRelayMac/Localization.swift` (UI strings)<br>`Resources/<lang>.lproj/InfoPlist.strings` (system permission prompts, Finder service name) |

> Adding a language: add the matching resource file on each platform; `Strings.cs`'s
> `Get(zh, en, ja, ko)` needs one more argument.
> Logs (`relay.log`, `NSLog`) are intentionally kept in Chinese so they can be read
> alongside the source; they are not UI strings.

## Build requirements

- Windows 10 2004 (build 19041) or later / Windows 11
  — WinRT is used to enumerate paired devices, hence the
  `net8.0-windows10.0.19041.0` TFM
- .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`)

```powershell
cd BlueDeskRelay
dotnet build -c Release
# output: bin\Release\net8.0-windows10.0.19041.0\BlueDeskRelay.exe
```

For a single-file build:

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true
# output: bin\Release\net8.0-windows10.0.19041.0\win-x64\publish\BlueDeskRelay.exe
```

### Build gotcha: missing local NuGet source (NU1301)

If `dotnet restore` fails with:

```
error NU1301: The local source 'd:\Program Files (x86)\Microsoft Visual Studio\Shared\NuGetPackages' doesn't exist
```

this is a **stale global Visual Studio configuration on your machine**, not a problem
with the project. It comes from
`C:\Program Files (x86)\NuGet\Config\Microsoft.VisualStudio.FallbackLocation.config`,
which declares a `fallbackPackageFolders` entry pointing at a D: drive that doesn't exist here.

The repo ships a `nuget.config` at the root that clears the inherited fallback folders,
so builds run from this directory just work — no admin rights, no system changes.

Note it only applies to projects under this directory. Creating a new .NET project
elsewhere will hit the same error; copy `nuget.config` over, or fix the global config
above with admin rights.

## Usage

1. **Pair**: Windows Settings → Bluetooth → Add device, pair with the phone
   (BlueDesk-XXXXXX) once. Pairing sets up credentials for both the HID (keyboard/mouse)
   and SPP (data) channels.
2. **Phone**: open BlueDesk → the "Relay" tab at the bottom → turn on Relay.
3. **PC**: start `BlueDeskRelay.exe` (drop it into `shell:startup` to run at login).
   It auto-discovers the paired BlueDesk phone and connects; the tray shows "Connected".
   - If the phone shows up under its real model name (`S25U`, `SM-S9380`, …) instead of
     `BlueDesk*`, auto-discovery won't find it — pick it once via the tray menu
     **Connect Device ▸** and it will be remembered.
4. **Transfer**:
   - PC A: `Ctrl+Alt+B` or the tray menu sends the clipboard → a record appears on the
     phone's Relay page;
   - Phone: tap "Forward…" on that record and pick PC B → B writes the clipboard / saves
     the file and shows a balloon notification.

## The Connect Device menu

| Element | Meaning |
|---|---|
| ✓ checked | The device currently connected |
| ★ name (remembered) | The remembered device while disconnected; reconnects and restarts prefer it |
| Refresh device list | Re-read the system pairing list (use right after pairing a new device) |
| Clear preferred | Forget the remembered device and go back to auto-discovering the first `BlueDesk*` |

The remembered address is stored in `%APPDATA%\BlueDesk\relay.json`. Reconnecting with a
cached address is direct (under a second) instead of a 10–20 second Bluetooth inquiry;
if the address goes stale (new phone / unpaired) it falls back to device discovery.

## Technical notes

- Bluetooth stack: [32feet.NET](https://github.com/inthehand/32feet)
  (NuGet `InTheHand.Net.Bluetooth` 4.1.40)
  — pinned to 4.1.40, **do not upgrade to 4.1.44**: that release changed the
  `BluetoothClient.DiscoverDevices` overloads and breaks the build
- Device enumeration: WinRT `DeviceInformation.FindAllAsync` reads the system pairing
  cache (~300 ms, no radio inquiry). 32feet's `DiscoverDevices` only has a single-parameter
  overload and runs a full inquiry (10–20 s) every time, so it can't be used for the menu
- Service UUID: `a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1`
  (matches `TransferProtocol.SERVICE_UUID` on the phone)
- Frame format: 11-byte header (MAGIC / version / type / FLAGS / length / CRC32 low 16 bits)
  plus payload — see `Protocol.cs`, byte-for-byte aligned with `TransferProtocol.kt` on the
  phone; files are chunked at 4 KB
- Note: the SPP channel measures roughly 50–200 KB/s, so it suits text and files of a few MB

## Source layout

```
BlueDeskRelay/
  RelayApp.cs        Tray UI, hotkeys, clipboard, Connect Device menu
  PhoneLink.cs       RFCOMM connect / send / receive / reconnect watchdog
  Protocol.cs        Frame codec (byte-for-byte aligned with the phone)
  PairedDevices.cs   Paired device enumeration (WinRT)
  RelaySettings.cs   Remembered device address (%APPDATA%\BlueDesk\relay.json)
```
