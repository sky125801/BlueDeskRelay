# BlueDesk リレー（Windows 版）

[简体中文](README.md) | [English](README.en.md) | **日本語** | [한국어](README.ko.md)

BlueDesk スマートフォンアプリの「リレー」ページと組み合わせて使う Windows 常駐（トレイ）アプリです。
クラシック Bluetooth の SPP データチャネルでスマートフォンと通信し、
**PC A → スマートフォン → PC B** のテキスト／小容量ファイル転送を実現します。

> データチャネルはキーボード・マウス用の HID チャネルとは独立しているため、
> 一度の Bluetooth ペアリングで両方を同時に使えます。

## 機能

- **送信**：トレイアイコンの右クリックメニューからクリップボード／ファイル（64MB 以下）を送信。
  またはグローバルホットキー `Ctrl+Alt+B` でクリップボードを送信
- **エクスプローラの右クリックから送信**：ファイルを選択 → 右クリック →「BlueDesk に送信」で
  スマートフォンへ直接渡します。アプリが起動していなければ自動で起動し、接続後に送信します
  （HKCU への登録なので管理者権限は不要）
- **ホットキーでファイル送信**：エクスプローラでファイルを選択して `Ctrl+Alt+F`。
  エクスプローラが前面にない場合は、`Ctrl+C` でコピーしたファイルにフォールバックします
- **受信**：テキストは自動でクリップボードへ（`Ctrl+V` でそのまま貼り付け、中国語もそのまま）。
  ファイルは `Downloads\BlueDesk` に保存
- **手動接続**：メニュー「デバイス接続 ▸」にペアリング済みの全デバイスを表示し、クリックで接続
  （接続中のデバイスにはチェック、記憶デバイスには ★）。再接続・再起動時は記憶デバイスを優先し、
  「記憶をクリア」で自動検出に戻ります
- **状態**：切断時は 5 秒ごとに自動再接続。接続・送受信はバルーン通知でお知らせします

## 多言語対応

3 プラットフォーム（Android / Windows / macOS）すべてで
**简体中文・English・日本語・한국어** に対応しています。
システムの言語設定に自動で追従し、それ以外の言語は英語にフォールバックします。

| プラットフォーム | 文言の場所 |
|---|---|
| Windows | `BlueDeskRelayWindows/Strings.cs`（4 言語を内蔵、`CultureInfo.CurrentUICulture` で判定） |
| Android | `app/src/main/res/values*/strings.xml`（英語がデフォルト + `values-zh` / `-ja` / `-ko`） |
| macOS | `Sources/BlueDeskRelayMac/Localization.swift`（UI 文言）<br>`Resources/<lang>.lproj/InfoPlist.strings`（システム権限ダイアログ、Finder サービス名） |

> 言語を追加する場合：各プラットフォームに対応するリソースを追加します。
> `Strings.cs` の `Get(zh, en, ja, ko)` は引数を 1 つ増やす必要があります。
> ログ（`relay.log`、`NSLog`）はソースと照らし合わせて調査するため意図的に中国語のままにしており、
> UI 文言には含めていません。

## ビルド要件

- Windows 10 2004（build 19041）以降 / Windows 11
  — ペアリング済みデバイスの列挙に WinRT を使うため、TFM は `net8.0-windows10.0.19041.0`
- .NET 8 SDK（`winget install Microsoft.DotNet.SDK.8`）

```powershell
cd BlueDeskRelay
dotnet build -c Release
# 出力：bin\Release\net8.0-windows10.0.19041.0\BlueDeskRelay.exe
```

単一ファイルで出力する場合：

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true
# 出力：bin\Release\net8.0-windows10.0.19041.0\win-x64\publish\BlueDeskRelay.exe
```

### ビルドの落とし穴：ローカル NuGet ソースが存在しない（NU1301）

`dotnet restore` が次のエラーで失敗する場合：

```
error NU1301: ローカル ソース 'd:\Program Files (x86)\Microsoft Visual Studio\Shared\NuGetPackages' が存在しません
```

これは**お使いのマシンにある Visual Studio のグローバル設定が古い**ことが原因で、
プロジェクト側の問題ではありません。発生元は
`C:\Program Files (x86)\NuGet\Config\Microsoft.VisualStudio.FallbackLocation.config` で、
存在しない D ドライブを指す `fallbackPackageFolders` が宣言されています。

リポジトリのルートに `nuget.config` を置いてあるため、このディレクトリからビルドすれば
継承されたフォールバックフォルダがクリアされます。管理者権限もシステム設定の変更も不要です。

ただしこの設定は**このディレクトリ配下のプロジェクトにのみ有効**です。
別の場所で .NET プロジェクトを作ると同じエラーになるので、`nuget.config` をコピーするか、
管理者権限で上記のグローバル設定を修正してください。

## 使い方

1. **ペアリング**：Windows の設定 → Bluetooth → デバイスの追加 から、スマートフォン
   （BlueDesk-XXXXXX）と一度ペアリングします。ペアリング時に HID（キーボード・マウス）と
   SPP（データ）の両チャネルの資格情報が作成されます。
2. **スマートフォン側**：BlueDesk を開く → 下部の「リレー」タブ → リレーを有効にする。
3. **PC 側**：`BlueDeskRelay.exe` を起動します（`shell:startup` に入れておけばログイン時に自動起動）。
   ペアリング済みの BlueDesk スマートフォンを自動検出して接続し、トレイに「接続済み」と表示されます。
   - スマートフォンが `BlueDesk*` ではなく実際の機種名（`S25U`、`SM-S9380` など）で表示される場合、
     自動検出では見つかりません。トレイメニューの **デバイス接続 ▸** から一度手動で選べば記憶されます。
4. **転送**：
   - PC A：`Ctrl+Alt+B` またはトレイメニューでクリップボードを送信 → スマートフォンの
     「リレー」ページに履歴が現れます；
   - スマートフォン：その履歴の「転送…」をタップして PC B を選択 → B 側が自動でクリップボードに
     書き込み／ファイルを保存し、バルーン通知を表示します。

## 「デバイス接続」メニューの説明

| 要素 | 意味 |
|---|---|
| ✓ チェック | 現在接続中のデバイス |
| ★ 名前（記憶） | 未接続時の記憶デバイス。再接続・再起動後はこれを優先 |
| デバイスリスト更新 | システムのペアリング一覧を読み直します（新しいデバイスをペアリングした直後など） |
| 記憶をクリア | 記憶デバイスを忘れ、最初の `BlueDesk*` の自動検出に戻します |

記憶したアドレスは `%APPDATA%\BlueDesk\relay.json` に保存されます。アドレスをキャッシュすると
再接続は直接接続（1 秒以内）になり、毎回十数秒かかる Bluetooth 検索を避けられます。
アドレスが無効になった場合（機種変更・ペアリング解除）は自動検出にフォールバックします。

## 技術メモ

- Bluetooth スタック：[32feet.NET](https://github.com/inthehand/32feet)
  （NuGet `InTheHand.Net.Bluetooth` 4.1.40）
  — 4.1.40 に固定しています。**4.1.44 に上げないでください**：このバージョンは
  `BluetoothClient.DiscoverDevices` のオーバーロードが変更されており、ビルドが通らなくなります
- デバイス列挙：WinRT の `DeviceInformation.FindAllAsync` でシステムのペアリングキャッシュを
  読みます（約 300ms、無線検索は行いません）。32feet の `DiscoverDevices` は単一引数の
  オーバーロードしかなく、毎回完全な検索（10〜20 秒）が走るためメニューには使えません
- サービス UUID：`a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1`
  （スマートフォン側の `TransferProtocol.SERVICE_UUID` と一致）
- フレーム形式：11 バイトのヘッダ（MAGIC / バージョン / 種別 / FLAGS / 長さ / CRC32 下位 16bit）
  + ペイロード。詳細は `Protocol.cs` を参照。スマートフォン側の `TransferProtocol.kt` と
  バイト単位で一致しており、ファイルは 4KB ごとに分割されます
- 補足：SPP チャネルは実測 50〜200 KB/s 程度です。テキストや数 MB 程度のファイルに適しています

## ソース構成

```
BlueDeskRelay/
  RelayApp.cs        トレイ UI、ホットキー、クリップボード、デバイス接続メニュー
  PhoneLink.cs       RFCOMM 接続 / 送受信 / 切断時の再接続監視
  Protocol.cs        フレームのエンコード・デコード（スマートフォン側とバイト単位で一致）
  PairedDevices.cs   ペアリング済みデバイスの列挙（WinRT）
  RelaySettings.cs   記憶デバイスのアドレス（%APPDATA%\BlueDesk\relay.json）
```
