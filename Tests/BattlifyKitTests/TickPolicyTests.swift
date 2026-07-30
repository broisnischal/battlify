import Testing
import Foundation
@testable import BattlifyKit

@Suite("Tick policy")
struct TickPolicyTests {

    /// Closed, on battery, nothing configured that needs watching: the only time the
    /// loop can run is inside a maintenance dark wake, so it must back off.
    @Test("A closed Mac on battery with nothing to manage ticks slowly")
    func backsOffWhenIdle() {
        let cfg = BattlifyConfig()
        #expect(TickPolicy.interval(cfg, onExternalPower: false, lidClosed: true) == TickPolicy.idle)
    }

    @Test("Plugged in always ticks fast, closed or not")
    func staysFastOnAC() {
        let cfg = BattlifyConfig()
        #expect(TickPolicy.interval(cfg, onExternalPower: true, lidClosed: true) == TickPolicy.active)
        #expect(TickPolicy.interval(cfg, onExternalPower: true, lidClosed: false) == TickPolicy.active)
    }

    @Test("An open lid ticks fast — the user can plug in at any moment")
    func staysFastWhenOpen() {
        let cfg = BattlifyConfig()
        #expect(TickPolicy.interval(cfg, onExternalPower: false, lidClosed: false) == TickPolicy.active)
    }

    /// Each of these has to act on time even with the lid shut, so none may back off.
    @Test("Anything that must react while closed holds the fast tick")
    func featuresThatNeedTheFastTick() {
        var keepAwake = BattlifyConfig();   keepAwake.keepAwake = true
        var discharge = BattlifyConfig();   discharge.dischargeEnabled = true
        var calibrate = BattlifyConfig();   calibrate.calibrateToFull = true
        var paused = BattlifyConfig();      paused.pauseUntil = Date(timeIntervalSince1970: 1_800_000_000)
        var scheduled = BattlifyConfig()
        scheduled.schedules = [ChargeSchedule()]
        var readyBy = BattlifyConfig();     readyBy.readyBy.enabled = true

        for cfg in [keepAwake, discharge, calibrate, paused, scheduled, readyBy] {
            #expect(TickPolicy.interval(cfg, onExternalPower: false, lidClosed: true) == TickPolicy.active)
        }
    }

    @Test("Backing off is a real reduction, not a token one")
    func backoffIsWorthIt() {
        // A 35s dark wake should see one pass, not three or four.
        #expect(TickPolicy.idle >= TickPolicy.active * 4)
    }
}
