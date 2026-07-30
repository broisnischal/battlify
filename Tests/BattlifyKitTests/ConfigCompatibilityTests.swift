import Testing
import Foundation
@testable import BattlifyKit

@Suite("Config compatibility")
struct ConfigCompatibilityTests {

    @Test("A config written while fan boost existed still loads")
    func decodesConfigWithRemovedFanKeys() throws {
        // Fan boost shipped in a build that wrote these keys. Removing the feature
        // must not brick those configs — the rest has to decode as normal.
        let json = #"""
        {"chargeLimitEnabled":true,"chargeLimit":75,"sleepDepth":"deep",
         "fanBoostEnabled":true,"fanBoostPercent":70,
         "fanBoostMinCpu":40,"fanBoostOnlyWhenKeepAwake":true}
        """#
        let config = try JSONDecoder().decode(BattlifyConfig.self, from: Data(json.utf8))
        #expect(config.chargeLimitEnabled)
        #expect(config.chargeLimit == 75)
        #expect(config.sleepDepth == .deep)
    }
}
