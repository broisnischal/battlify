import Testing
@testable import BattlifyKit

@Suite("macOS charge limit steps")
struct NativeChargeLimitStepTests {
    let steps = [80, 85, 90, 95, 100]

    @Test("A target on a step stops on that step")
    func onStep() {
        #expect(NativeChargeLimit.step(for: 80, in: steps) == 80)
        #expect(NativeChargeLimit.step(for: 90, in: steps) == 90)
    }

    /// Never fuller than asked: a hold thrown at 83% parks on 80, not 85.
    @Test("Between steps rounds down")
    func roundsDown() {
        #expect(NativeChargeLimit.step(for: 83, in: steps) == 80)
        #expect(NativeChargeLimit.step(for: 99, in: steps) == 95)
    }

    /// The floor is the lowest this Mac can hold at all; the app warns wherever this applies.
    @Test("Below the floor stops at the floor")
    func belowFloor() {
        #expect(NativeChargeLimit.step(for: 70, in: steps) == 80)
        #expect(NativeChargeLimit.step(for: 20, in: steps) == 80)
    }

    @Test("At the top step there's nothing to enforce")
    func top() {
        #expect(NativeChargeLimit.step(for: 100, in: steps) == nil)
    }

    @Test("No steps means no native limit")
    func unsupported() {
        #expect(NativeChargeLimit.step(for: 80, in: []) == nil)
    }
}

@Suite("MagSafe status colour")
struct MagSafeStatusTests {
    @Test("Taking charge is amber")
    func charging() {
        #expect(MagSafeLED.status(settling: false, onExternalPower: true,
                                  adapterCut: false, charging: true) == .orange)
    }

    /// Held at a limit, full, or macOS's own limit reached: plugged in and not charging.
    @Test("On the cable and not charging is green")
    func held() {
        #expect(MagSafeLED.status(settling: false, onExternalPower: true,
                                  adapterCut: false, charging: false) == .green)
    }

    /// The case that showed amber through a hold: the snapshot still said charging when
    /// the adapter had just been cut.
    @Test("A cut adapter is green whatever the snapshot says")
    func adapterCut() {
        #expect(MagSafeLED.status(settling: false, onExternalPower: true,
                                  adapterCut: true, charging: true) == .green)
    }

    @Test("Unplugged hands the light to macOS; settling turns it off")
    func unpluggedAndSettling() {
        #expect(MagSafeLED.status(settling: false, onExternalPower: false,
                                  adapterCut: false, charging: false) == .system)
        #expect(MagSafeLED.status(settling: true, onExternalPower: true,
                                  adapterCut: false, charging: true) == .off)
    }
}
