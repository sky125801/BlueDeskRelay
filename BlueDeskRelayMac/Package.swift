// swift-tools-version:5.9
// BlueDesk 互传助手（macOS 端）—— 菜单栏程序，IOBluetooth 经典蓝牙 RFCOMM
import PackageDescription

let package = Package(
    name: "BlueDeskRelayMac",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "BlueDeskRelayMac",
            path: "Sources/BlueDeskRelayMac",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Carbon"),   // 全局热键 RegisterEventHotKey
            ]
        )
    ]
)
