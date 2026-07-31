import Testing
import Foundation
@testable import BattlifyKit

@Suite("Delayed hibernation")
struct HibernatePolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func cfg(after: Int, depth: SleepDepth = .normal) -> BattlifyConfig {
        var c = BattlifyConfig(); c.hibernateAfterMinutes = after; c.sleepDepth = depth; return c
    }
    private func decide(_ c: BattlifyConfig, ac: Bool = false, closedFor: Double? = 0,
                        applied: Bool = false) -> HibernatePolicy.Decision {
        HibernatePolicy.decide(config: c, onExternalPower: ac,
                               lidClosedSince: closedFor.map { t0.addingTimeInterval(-$0) },
                               now: t0, applied: applied)
    }

    @Test("Off by default — an unconfigured Mac is never switched")
    func offByDefault() {
        #expect(decide(BattlifyConfig(), closedFor: 86_400) == .hold)
    }

    @Test("A short close stays instant")
    func shortCloseHolds() {
        #expect(decide(cfg(after: 60), closedFor: 5 * 60) == .hold)
    }

    @Test("Past the delay, the Mac hibernates")
    func longCloseHibernates() {
        #expect(decide(cfg(after: 60), closedFor: 61 * 60) == .hibernate)
    }

    @Test("Exactly on the delay counts")
    func boundaryHibernates() {
        #expect(decide(cfg(after: 60), closedFor: 60 * 60) == .hibernate)
    }

    @Test("Only switches once per lid-closed spell")
    func doesNotReapply() {
        #expect(decide(cfg(after: 60), closedFor: 5 * 3600, applied: true) == .hold)
    }

    @Test("Opening the lid restores the user's setting")
    func lidOpenRestores() {
        #expect(decide(cfg(after: 60), closedFor: nil, applied: true) == .restore)
        #expect(decide(cfg(after: 60), closedFor: nil, applied: false) == .hold)
    }

    @Test("Plugging in restores it too — there's nothing to save on AC")
    func acRestores() {
        #expect(decide(cfg(after: 60), ac: true, closedFor: 5 * 3600, applied: true) == .restore)
        #expect(decide(cfg(after: 60), ac: true, closedFor: 5 * 3600) == .hold)
    }

    /// The user asked for permanent deep sleep, so the setting is theirs — we must
    /// not start toggling it underneath them, and must hand back anything we took.
    @Test("Permanent Deep sleep wins; we don't fight the user's own setting")
    func deepSleepOwnsIt() {
        #expect(decide(cfg(after: 60, depth: .deep), closedFor: 5 * 3600) == .hold)
        #expect(decide(cfg(after: 60, depth: .deep), closedFor: 5 * 3600, applied: true) == .restore)
    }

    @Test("Turning the feature off hands the setting back")
    func disablingRestores() {
        #expect(decide(cfg(after: 0), closedFor: 5 * 3600, applied: true) == .restore)
    }
}
