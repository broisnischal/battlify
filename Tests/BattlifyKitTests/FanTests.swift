import Testing
import Foundation
@testable import BattlifyKit

@Suite("Fan control")
struct FanTests {

    // A fan with the range this feature was developed against (M3 Pro).
    private let low = 2317.0, high = 6800.0

    @Test("0% is the fan's floor — never below it")
    func floorIsRespected() {
        // The whole safety argument rests on this: no input may produce an RPM
        // under what the firmware itself would allow.
        #expect(FanControl.target(forPercent: 0, min: low, max: high) == low)
        #expect(FanControl.target(forPercent: -50, min: low, max: high) == low)
        #expect(FanControl.target(forPercent: Int.min, min: low, max: high) == low)
    }

    @Test("100% is the ceiling, and nothing exceeds it")
    func ceilingIsRespected() {
        #expect(FanControl.target(forPercent: 100, min: low, max: high) == high)
        #expect(FanControl.target(forPercent: 500, min: low, max: high) == high)
        #expect(FanControl.target(forPercent: Int.max, min: low, max: high) == high)
    }

    @Test("Percentages map across the fan's own range")
    func mapsAcrossRange() {
        #expect(FanControl.target(forPercent: 50, min: low, max: high) == 4559)  // midpoint
        let sixty = FanControl.target(forPercent: 60, min: low, max: high)
        #expect(sixty > low && sixty < high)
        // Monotonic: more percent is never less airflow.
        var previous = 0.0
        for percent in stride(from: 0, through: 100, by: 5) {
            let rpm = FanControl.target(forPercent: percent, min: low, max: high)
            #expect(rpm >= previous)
            previous = rpm
        }
    }

    @Test("A degenerate range can't produce something below max")
    func degenerateRange() {
        #expect(FanControl.target(forPercent: 0, min: 3000, max: 3000) == 3000)
        // Nonsense ordering must not yield a value under the reported max.
        #expect(FanControl.target(forPercent: 0, min: 5000, max: 3000) == 3000)
    }

    @Test("A fan reports where it sits in its range")
    func percentOfRange() {
        func fan(_ rpm: Double) -> FanState {
            FanState(index: 0, rpm: rpm, minRPM: low, maxRPM: high, forced: false)
        }
        #expect(fan(low).percentOfRange == 0)
        #expect(fan(high).percentOfRange == 100)
        #expect(fan(4559).percentOfRange == 50)
        // Out-of-band readings clamp rather than report nonsense.
        #expect(fan(0).percentOfRange == 0)
        #expect(fan(99_999).percentOfRange == 100)
        #expect(fan(low).title == "Fan 1")
    }

    @Test("Fan boost defaults are off and sane")
    func configDefaults() {
        let config = BattlifyConfig()
        #expect(!config.fanBoostEnabled)                 // never on without asking
        #expect(config.fanBoostPercent == 60)
        #expect(config.fanBoostMinCpu == 50)
        #expect(!config.fanBoostOnlyWhenKeepAwake)
    }

    @Test("A config from before this feature loads with the boost off")
    func decodesLegacyConfig() throws {
        let json = #"{"chargeLimit":80,"chargeLimitEnabled":true}"#
        let config = try JSONDecoder().decode(BattlifyConfig.self, from: Data(json.utf8))
        #expect(!config.fanBoostEnabled)
        #expect(config.fanBoostPercent == 60)
    }

    @Test("The boost level is clamped when stored")
    func percentClampedInConfig() throws {
        #expect(BattlifyConfig(fanBoostPercent: 140).fanBoostPercent == 100)
        #expect(BattlifyConfig(fanBoostPercent: -20).fanBoostPercent == 0)
        #expect(BattlifyConfig(fanBoostMinCpu: -5).fanBoostMinCpu == 0)
    }

    @Test("The setting survives a round trip")
    func roundTrips() throws {
        var config = BattlifyConfig()
        config.fanBoostEnabled = true
        config.fanBoostPercent = 75
        config.fanBoostOnlyWhenKeepAwake = true
        let decoded = try JSONDecoder().decode(
            BattlifyConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }
}
