# BlueDesk 릴레이 (Windows)

[简体中文](README.md) | [English](README.en.md) | [日本語](README.ja.md) | **한국어**

BlueDesk 스마트폰 앱의 '릴레이' 페이지와 함께 사용하는 Windows 트레이 프로그램입니다.
클래식 블루투스 SPP 데이터 채널로 스마트폰과 통신하여
**PC A → 스마트폰 → PC B** 텍스트/소용량 파일 전송을 구현합니다.

> 데이터 채널은 키보드·마우스용 HID 채널과 독립적이므로,
> 한 번의 블루투스 페어링으로 두 채널을 동시에 사용할 수 있습니다.

## 기능

- **전송**: 트레이 아이콘을 우클릭하여 클립보드/파일(64MB 이하)을 전송하거나,
  전역 단축키 `Ctrl+Alt+B` 로 클립보드를 전송
- **탐색기 우클릭 전송**: 파일 선택 → 우클릭 → 'BlueDesk로 전송'을 누르면 스마트폰으로 바로 전달됩니다.
  앱이 실행 중이 아니면 자동으로 실행되고, 연결되면 전송합니다(HKCU 등록이라 관리자 권한 불필요)
- **단축키로 파일 전송**: 탐색기에서 파일을 선택한 뒤 `Ctrl+Alt+F`.
  탐색기가 전면에 없으면 `Ctrl+C` 로 복사한 파일로 대체합니다
- **수신**: 텍스트는 자동으로 클립보드에 기록(`Ctrl+V` 로 바로 붙여넣기, 중국어 원형 유지).
  파일은 `Downloads\BlueDesk` 에 저장
- **수동 연결**: 메뉴 '기기 연결 ▸'에 페어링된 모든 기기를 나열하고 클릭하면 연결됩니다
  (연결 중인 기기는 체크, 기억된 기기는 ★). 재연결·재시작 시 기억된 기기를 우선하며,
  '선호 기기 삭제'로 자동 검색으로 돌아갑니다
- **상태**: 연결이 끊기면 5초마다 자동 재연결. 연결·송수신은 풍선 알림으로 표시

## 다국어 지원

세 플랫폼(Android / Windows / macOS) 모두
**简体中文 · English · 日本語 · 한국어** 를 지원합니다.
시스템 언어 설정을 자동으로 따르며, 그 외 언어는 영어로 대체됩니다.

| 플랫폼 | 문구 위치 |
|---|---|
| Windows | `BlueDeskRelayWindows/Strings.cs` (4개 언어 내장, `CultureInfo.CurrentUICulture` 로 판별) |
| Android | `app/src/main/res/values*/strings.xml` (영어 기본 + `values-zh` / `-ja` / `-ko`) |
| macOS | `Sources/BlueDeskRelayMac/Localization.swift` (UI 문구)<br>`Resources/<lang>.lproj/InfoPlist.strings` (시스템 권한 안내, Finder 서비스 이름) |

> 언어 추가: 플랫폼마다 해당 리소스 파일을 추가하면 됩니다.
> `Strings.cs` 의 `Get(zh, en, ja, ko)` 는 인자를 하나 더 늘려야 합니다.
> 로그(`relay.log`, `NSLog`)는 소스와 대조해 확인하기 위해 의도적으로 중국어로 두었으며,
> UI 문구에 포함되지 않습니다.

## 빌드 요구 사항

- Windows 10 2004(build 19041) 이상 / Windows 11
  — 페어링된 기기 열거에 WinRT를 사용하므로 TFM은 `net8.0-windows10.0.19041.0`
- .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`)

```powershell
cd BlueDeskRelay
dotnet build -c Release
# 결과물: bin\Release\net8.0-windows10.0.19041.0\BlueDeskRelay.exe
```

단일 파일로 게시하려면:

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true
# 결과물: bin\Release\net8.0-windows10.0.19041.0\win-x64\publish\BlueDeskRelay.exe
```

### 빌드 시 함정: 로컬 NuGet 소스 없음(NU1301)

`dotnet restore` 가 아래 오류로 실패한다면:

```
error NU1301: 로컬 원본 'd:\Program Files (x86)\Microsoft Visual Studio\Shared\NuGetPackages'이(가) 없습니다
```

이는 **해당 PC의 Visual Studio 전역 설정이 오래된 것**이지 프로젝트 문제가 아닙니다. 원인은
`C:\Program Files (x86)\NuGet\Config\Microsoft.VisualStudio.FallbackLocation.config` 에
존재하지 않는 D 드라이브를 가리키는 `fallbackPackageFolders` 가 선언되어 있기 때문입니다.

저장소 루트에 `nuget.config` 를 두었으므로 이 디렉터리에서 빌드하면 상속된 대체 폴더가
비워집니다. 관리자 권한도, 시스템 설정 변경도 필요 없습니다.

다만 이 설정은 **이 디렉터리 하위 프로젝트에만 적용**됩니다. 다른 곳에서 .NET 프로젝트를 만들면
같은 오류가 나므로 `nuget.config` 를 복사하거나, 관리자 권한으로 위 전역 설정을 수정하세요.

## 사용 방법

1. **페어링**: Windows 설정 → Bluetooth → 장치 추가에서 스마트폰(BlueDesk-XXXXXX)과
   한 번 페어링합니다. 페어링 시 HID(키보드·마우스)와 SPP(데이터) 두 채널의 자격 증명이 만들어집니다.
2. **스마트폰**: BlueDesk 실행 → 하단 '릴레이' 탭 → 릴레이 켜기.
3. **PC**: `BlueDeskRelay.exe` 를 실행합니다(`shell:startup` 에 넣으면 로그인 시 자동 실행).
   페어링된 BlueDesk 스마트폰을 자동으로 찾아 연결하고, 트레이에 '연결됨'이 표시됩니다.
   - 스마트폰이 `BlueDesk*` 대신 실제 모델명(`S25U`, `SM-S9380` 등)으로 표시되면 자동 검색에서
     찾지 못합니다. 트레이 메뉴 **기기 연결 ▸** 에서 한 번 직접 선택하면 이후 기억됩니다.
4. **전송**:
   - PC A: `Ctrl+Alt+B` 또는 트레이 메뉴로 클립보드 전송 → 스마트폰 '릴레이' 페이지에 기록이 나타납니다;
   - 스마트폰: 해당 기록의 '전달…'을 눌러 PC B를 선택 → B가 자동으로 클립보드에 기록하거나
     파일을 저장하고 풍선 알림을 표시합니다.

## '기기 연결' 메뉴 설명

| 항목 | 의미 |
|---|---|
| ✓ 체크 | 현재 연결 중인 기기 |
| ★ 이름(기억) | 연결되지 않았을 때의 기억된 기기. 재연결·재시작 시 우선 |
| 기기 목록 새로고침 | 시스템 페어링 목록을 다시 읽습니다(새 기기를 페어링한 직후 등) |
| 선호 기기 삭제 | 기억된 기기를 잊고 첫 번째 `BlueDesk*` 자동 검색으로 복귀 |

기억된 주소는 `%APPDATA%\BlueDesk\relay.json` 에 저장됩니다. 주소를 캐시하면 재연결이
바로 연결(1초 이내)되어 매번 10~20초 걸리는 블루투스 검색을 피할 수 있습니다.
주소가 무효해지면(기기 교체·페어링 해제) 자동 검색으로 대체됩니다.

## 기술 노트

- 블루투스 스택: [32feet.NET](https://github.com/inthehand/32feet)
  (NuGet `InTheHand.Net.Bluetooth` 4.1.40)
  — 4.1.40 으로 고정되어 있습니다. **4.1.44 로 올리지 마세요**: 해당 버전은
  `BluetoothClient.DiscoverDevices` 오버로드가 바뀌어 빌드가 실패합니다
- 기기 열거: WinRT `DeviceInformation.FindAllAsync` 로 시스템 페어링 캐시를 읽습니다
  (약 300ms, 무선 검색 없음). 32feet 의 `DiscoverDevices` 는 단일 인자 오버로드뿐이라
  매번 전체 검색(10~20초)이 수행되므로 메뉴에는 쓸 수 없습니다
- 서비스 UUID: `a3bd7f2e-5c14-4a9e-9d1b-2f6e8c04bde1`
  (스마트폰의 `TransferProtocol.SERVICE_UUID` 와 동일)
- 프레임 형식: 11바이트 헤더(MAGIC / 버전 / 타입 / FLAGS / 길이 / CRC32 하위 16비트) + 페이로드.
  자세한 내용은 `Protocol.cs` 참고. 스마트폰의 `TransferProtocol.kt` 와 바이트 단위로 일치하며,
  파일은 4KB 단위로 분할됩니다
- 참고: SPP 채널은 실측 50~200 KB/s 정도로, 텍스트와 몇 MB 이내 파일에 적합합니다

## 소스 구조

```
BlueDeskRelay/
  RelayApp.cs        트레이 UI, 단축키, 클립보드, 기기 연결 메뉴
  PhoneLink.cs       RFCOMM 연결 / 송수신 / 연결 끊김 시 재연결 감시
  Protocol.cs        프레임 인코딩·디코딩 (스마트폰과 바이트 단위 일치)
  PairedDevices.cs   페어링된 기기 열거 (WinRT)
  RelaySettings.cs   기억된 기기 주소 (%APPDATA%\BlueDesk\relay.json)
```
