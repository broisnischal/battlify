import Foundation
import BattlifyKit

// battlify-helper: the privileged component. Writing SMC keys requires root, so
// this binary is meant to be run as root (via sudo for testing, or as a
// LaunchDaemon in production). The GUI never writes SMC directly.

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func openSMC() -> (SMC, ChargeController) {
    let smc = SMC()
    do {
        try smc.open()
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(2)
    }
    return (smc, ChargeController(smc: smc))
}

func requireRoot() {
    if getuid() != 0 {
        FileHandle.standardError.write(
            Data("error: this command needs root. Re-run with sudo.\n".utf8))
        exit(13)
    }
}

switch command {

case "dump":
    // Diagnostics: no writes, safe to run without root.
    let (smc, charge) = openSMC()
    defer { smc.close() }
    let snap = BatteryMonitor.read()
    print("Battery: \(snap.percentage)%  (\(snap.powerSource), charging=\(snap.isCharging))")
    print("Charge-control scheme: \(charge.schemeDescription)")
    print("Charge control supported: \(charge.isChargingControlSupported)")
    for key in ["CH0B", "CH0C", "CHTE", "CH0I", "CH0J", "CHIE", "ACLC"] {
        if smc.keyExists(key), let v = try? smc.read(key) {
            let hex = v.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("  \(key) [\(v.dataType)] = \(hex)")
        } else {
            print("  \(key) = (absent)")
        }
    }
    if charge.isChargingControlSupported {
        print("Charging currently enabled: \((try? charge.isChargingEnabled()).map(String.init(describing:)) ?? "unknown")")
    }

case "status":
    let (smc, charge) = openSMC()
    defer { smc.close() }
    let cfg = ConfigStore.load()
    let snap = BatteryMonitor.read()
    print("battery=\(snap.percentage)% limitEnabled=\(cfg.chargeLimitEnabled) limit=\(cfg.chargeLimit)% chargingEnabled=\((try? charge.isChargingEnabled()) ?? false)")

case "enable":
    requireRoot()
    let (smc, charge) = openSMC()
    defer { smc.close() }
    do { try charge.enableCharging(); print("charging enabled") }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

case "disable":
    requireRoot()
    let (smc, charge) = openSMC()
    defer { smc.close() }
    do { try charge.disableCharging(); print("charging disabled") }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

case "limit":
    // Set the limit and turn limiting on. GUI normally does this by writing the
    // config, but the CLI is handy for testing.
    requireRoot()
    guard let n = args.dropFirst().first.flatMap({ Int($0) }), (20...100).contains(n) else {
        FileHandle.standardError.write(Data("usage: battlify-helper limit <20-100>\n".utf8))
        exit(64)
    }
    var cfg = ConfigStore.load()
    cfg.chargeLimit = n
    cfg.chargeLimitEnabled = true
    do { try ConfigStore.save(cfg); print("limit set to \(n)% (enabled)") }
    catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }

case "daemon":
    requireRoot()
    Daemon.run()

default:
    print("""
    battlify-helper — privileged battery control

    Commands:
      dump            Show SMC/charge diagnostics (no root needed)
      status          Show current battery + limit state
      enable          Allow charging (root)
      disable         Stop charging (root)
      limit <20-100>  Set charge limit and enable limiting (root)
      daemon          Run the enforcement loop (root, used by LaunchDaemon)
    """)
}
