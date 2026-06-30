// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Battlify",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Battlify", targets: ["Battlify"]),
        .executable(name: "battlify-helper", targets: ["battlify-helper"])
    ],
    targets: [
        // Low-level SMC access (C). Requires root to *write*.
        .target(
            name: "CSMC",
            path: "Sources/CSMC"
        ),
        // Shared Swift library used by both the GUI and the privileged helper.
        .target(
            name: "BattlifyKit",
            dependencies: ["CSMC"],
            path: "Sources/BattlifyKit"
        ),
        // The menu bar GUI app (runs as the user).
        .executableTarget(
            name: "Battlify",
            dependencies: ["BattlifyKit"],
            path: "Sources/Battlify",
            linkerSettings: [
                // Wi-Fi power control.
                .linkedFramework("CoreWLAN"),
                // Bluetooth power control (private IOBluetoothPreference* symbols).
                .linkedFramework("IOBluetooth")
            ]
        ),
        // The privileged daemon/CLI (runs as root) that enforces the charge limit.
        .executableTarget(
            name: "battlify-helper",
            dependencies: ["BattlifyKit"],
            path: "Sources/battlify-helper"
        )
    ]
)
