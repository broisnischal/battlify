// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Battlify",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Battlify", targets: ["Battlify"]),
        .executable(name: "battlify-helper", targets: ["battlify-helper"]),
        .executable(name: "licensetool", targets: ["licensetool"])
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
                .linkedFramework("IOBluetooth"),
                // Display brightness control (private DisplayServices framework).
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "DisplayServices"
                ])
            ]
        ),
        // The privileged daemon/CLI (runs as root) that enforces the charge limit.
        .executableTarget(
            name: "battlify-helper",
            dependencies: ["BattlifyKit"],
            path: "Sources/battlify-helper"
        ),
        // Seller-side license key generator/signer (not shipped in the app).
        .executableTarget(
            name: "licensetool",
            dependencies: ["BattlifyKit"],
            path: "Sources/licensetool"
        )
    ]
)
