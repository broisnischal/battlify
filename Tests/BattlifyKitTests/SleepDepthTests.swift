import Testing
import Foundation
@testable import BattlifyKit

@Suite("Sleep depth")
struct SleepDepthTests {

    @Test("Each depth maps to the hibernatemode pmset expects")
    func hibernateModes() {
        #expect(SleepDepth.normal.hibernateMode == 3)   // macOS default
        #expect(SleepDepth.deep.hibernateMode == 25)    // memory powered down
    }

    @Test("New configs default to normal sleep")
    func defaultsToNormal() {
        #expect(BattlifyConfig().sleepDepth == .normal)
        #expect(BattlifyConfig.default.sleepDepth == .normal)
    }

    @Test("A config written before this setting existed loads as normal")
    func decodesLegacyConfig() throws {
        // Deep sleep changes how the Mac wakes, so an upgrade must never opt a
        // user into it silently.
        let json = #"{"chargeLimitEnabled":true,"chargeLimit":80}"#
        let config = try JSONDecoder().decode(BattlifyConfig.self, from: Data(json.utf8))
        #expect(config.sleepDepth == .normal)
        #expect(config.chargeLimit == 80)
    }

    @Test("The setting survives a round trip")
    func roundTrips() throws {
        var config = BattlifyConfig()
        config.sleepDepth = .deep
        let decoded = try JSONDecoder().decode(
            BattlifyConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.sleepDepth == .deep)
        #expect(decoded == config)
    }

    @Test("Every depth is described for the picker")
    func hasCopy() {
        for depth in SleepDepth.allCases {
            #expect(!depth.title.isEmpty)
            #expect(!depth.summary.isEmpty)
        }
    }
}
