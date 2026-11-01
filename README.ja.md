<p align="center">
  <img src="ic_launcher.png" width="120" height="120" alt="BlueDesk アプリアイコン">
</p>

<h1 align="center">BlueDesk</h1>

<p align="center">
  <b>メインアプリ</b>：BlueDesk（Android）
</p>

<p align="center">
  リレー · 3 プラットフォーム向けコンパニオンアプリ（Windows / Android / macOS）
</p>

<p align="center">
  <a href="README.md">简体中文</a> | <a href="README.en.md">English</a> | <b>日本語</b> | <a href="README.ko.md">한국어</a>
</p>

BlueDesk スマートフォンアプリの「リレー」ページと組み合わせて使う、3 プラットフォーム向けの
コンパニオンアプリ群です。クラシック Bluetooth の SPP データチャネルでスマートフォンと通信し、
**PC A → スマートフォン → PC B** のテキスト／小容量ファイル転送をワンクリックで実現します。
スマートフォンが中継役になるため、どの端末もスマートフォンとやり取りでき、
さらに別の PC へ転送することもできます。

> データチャネルはキーボード・マウス用の HID チャネルとは独立しているため、
> 一度の Bluetooth ペアリングで両方を同時に使えます。

本リポジトリには各プラットフォームの実装が入っています。プロトコルは共通なので
**相互に混在利用できます** —— Windows から macOS へ、Android から Windows へ、いずれも可能です。

## 3 プラットフォームの機能比較

| 機能 | Android | Windows | macOS |
|---|:---:|:---:|:---:|
| テキスト送信 | ✓ 入力欄 / 貼り付け / 他アプリの共有受け取り | ✓ クリップボード | ✓ クリップボード |
| 単一ファイル送信 | ✓ | ✓ | ✓ |
| フォルダ送信 | ✓ SAF のディレクトリツリー経由 | ✓ `BATCH_*` フレーム | — |
| テキスト受信 → クリップボード | ✓ 通知も表示 | ✓ バルーンも表示 | ✓ 通知も表示 |
| ファイル受信 | ✓ `Download/BlueDesk` | ✓ `Downloads\BlueDesk` | ✓ `~/Downloads/BlueDesk` |
| フォルダ受信 | ✓ | ✓ | — |
| グローバルホットキー | — | `Ctrl+Alt+B` / `Ctrl+Alt+F` | `Ctrl+Opt+B` / `Ctrl+Opt+F` |
| OS 連携 | システムの共有先 | エクスプローラの右クリック | Finder の「サービス」 |
| バックグラウンド常駐 | フォアグラウンドサービス + 起動時自動開始 | トレイ + `shell:startup` | メニューバー + ログイン項目 |
| スマホ側の転送上限に追従 | ✓ | ✓ | — 64 MB 固定 |

`—` はそのプラットフォームでは未実装という意味です。他の 2 端末間の転送には影響しません。

## 各プラットフォームの概要

### Android

Kotlin + Jetpack Compose。フォアグラウンドサービスで接続を維持します。
他アプリからのテキストやファイルをシステムの共有先として受け取れ、フォルダ送信にも対応します。

- **要件**：JDK 17、Android SDK 36（`minSdk 29` / `targetSdk 36`）
- **ビルド**：`cd BlueDeskRelayAndroid && ./gradlew assembleDebug`
  → 出力 `app/build/outputs/apk/debug/app-debug.apk`
- **ソース**：`BlueDeskRelayAndroid/app/src/main/java/com/lingzhi/bluedesk/relayandroid/`

### Windows

.NET 8 WinForms のトレイアプリ。グローバルホットキーと、エクスプローラの右クリック
「BlueDesk に送信」に対応します。

- **要件**：Windows 10 2004（build 19041）以降、.NET 8 SDK
- **ビルド**：`cd BlueDeskRelayWindows && dotnet build -c Release`
  → 出力 `bin\Release\net8.0-windows10.0.19041.0\BlueDeskRelay.exe`
- **詳細**：[BlueDeskRelayWindows/README.md](BlueDeskRelayWindows/README.md)
  （NuGet `NU1301` のビルド時の落とし穴、デバイス接続メニューの説明を含む）

### macOS

Swift + SwiftPM のメニューバーアプリ（`LSUIElement`）。IOBluetooth のクラシック RFCOMM を使用し、
Finder の「サービス」とグローバルホットキーに対応します。

- **要件**：macOS 12 以降、Xcode Command Line Tools
- **ビルド**：`cd BlueDeskRelayMac && ./bundle.sh`
  → 出力 `BlueDesk Relay.app`
- **詳細**：[BlueDeskRelayMac/README.md](BlueDeskRelayMac/README.md)

## 通信プロトコル

3 実装はバイト単位で一致しています。プロトコル定義は
`RelayProtocol.kt`（Android）、`Protocol.cs`（Windows）、`Protocol.swift`（macOS）にあります。

- **サービス UUID**：`a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1`
- **フレーム形式**：11 バイトのヘッダ（MAGIC / バージョン / 種別 / FLAGS / 長さ / CRC32 下位 16bit）
  + ペイロード
- **フレーム種別**：`HELLO`、`TEXT`、`FILE_META`、`FILE_CHUNK`、`FILE_END`、`ACK`、`PING`、`PONG`、
  `ERROR`、`CONFIG`、`BATCH_META`、`BATCH_END`
- **分割**：ファイルは 4 KB 単位で分割して送信
- **転送上限**：既定 64 MB。スマートフォンから `CONFIG` フレームで一括指定されます（0 は無制限）
- **性能**：SPP チャネルは実測 50〜200 KB/s 程度で、テキストや数 MB 程度のファイルに適しています

## 多言語対応

3 プラットフォームすべてで **简体中文・English・日本語・한국어** に対応しています。
システムの言語設定に自動で追従し、それ以外の言語は英語にフォールバックします。

| プラットフォーム | 文言の場所 |
|---|---|
| Android | `app/src/main/res/values*/strings.xml`（英語がデフォルト + `values-zh` / `-ja` / `-ko`） |
| Windows | `BlueDeskRelayWindows/Strings.cs`（4 言語を内蔵、`CultureInfo.CurrentUICulture` で判定） |
| macOS | `Sources/BlueDeskRelayMac/Localization.swift`（UI 文言）<br>`Resources/<lang>.lproj/InfoPlist.strings`（システム権限ダイアログ、Finder サービス名） |

> 言語を追加する場合：各プラットフォームに対応するリソースを追加します。
> `Strings.cs` の `Get(zh, en, ja, ko)` は引数を 1 つ増やす必要があります。
> ログ（`relay.log`、`NSLog`）はソースと照らし合わせて調査するため意図的に中国語のままにしており、
> UI 文言には含めていません。

この README 自体も 4 言語で用意しています。各ファイル先頭の切り替えリンクをご利用ください。

## 使い方（共通）

1. **ペアリング**：システムの Bluetooth 設定でスマートフォン（`BlueDesk-XXXXXX`）と一度
   ペアリングします。ペアリング時に HID（キーボード・マウス）と SPP（データ）の両チャネルの
   資格情報が作成されます。
2. **スマートフォン側**：BlueDesk を開く → 下部の「リレー」タブ → リレーを有効にする。
3. **PC 側**：お使いのプラットフォームのアプリを起動します。ペアリング済みの BlueDesk
   スマートフォンを自動検出して接続します。
   スマートフォンが `BlueDesk*` ではなく実際の機種名（`S25U`、`SM-S9380` など）で表示される場合、
   自動検出で見つからないことがあります。「デバイス接続」から一度手動で選べば記憶されます。
4. **転送**：PC A が送信 → スマートフォンの「リレー」ページに履歴が表示 → 「転送…」をタップして
   PC B を選択 → B 側が自動でクリップボードに書き込むかファイルを保存し、通知を表示します。

## ライセンス

[Apache License 2.0](LICENSE)
