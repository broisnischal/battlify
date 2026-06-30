// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BattPie",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BattPie", targets: ["BattPie"]),
        .executable(name: "battpie-helper", targets: ["battpie-helper"])
    ],
    targets: [
        // Low-level SMC access (C). Requires root to *write*.
        .target(
            name: "CSMC",
            path: "Sources/CSMC"
        ),
        // Shared Swift library used by both the GUI and the privileged helper.
        .target(
            name: "BattPieKit",
            dependencies: ["CSMC"],
            path: "Sources/BattPieKit"
        ),
        // The menu bar GUI app (runs as the user).
        .executableTarget(
            name: "BattPie",
            dependencies: ["BattPieKit"],
            path: "Sources/BattPie",
            linkerSettings: [
                // Wi-Fi power control.
                .linkedFramework("CoreWLAN"),
                // Bluetooth power control (private IOBluetoothPreference* symbols).
                .linkedFramework("IOBluetooth")
            ]
        ),
        // The privileged daemon/CLI (runs as root) that enforces the charge limit.
        .executableTarget(
            name: "battpie-helper",
            dependencies: ["BattPieKit"],
            path: "Sources/battpie-helper"
        )
    ]
)
