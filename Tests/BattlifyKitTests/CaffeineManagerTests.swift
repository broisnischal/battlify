import Testing
import Foundation
import IOKit.pwr_mgt
@testable import BattlifyKit

// MARK: - Test doubles

/// Records acquire/release calls and tracks how many holds are live, so tests can
/// assert the manager never stacks assertions and always balances holds.
final class FakeKeepAwake: KeepAwakeAsserting, @unchecked Sendable {
    private let lock = NSLock()
    private var _acquireCount = 0
    private var _releaseCount = 0
    private var _held: Set<UInt32> = []
    private var _next: UInt32 = 1

    var acquireCount: Int { lock.withLock { _acquireCount } }
    var releaseCount: Int { lock.withLock { _releaseCount } }
    var heldCount: Int { lock.withLock { _held.count } }

    func acquire(reason: String) -> UInt32 {
        lock.withLock {
            _acquireCount += 1
            let token = _next; _next += 1
            _held.insert(token)
            return token
        }
    }

    func release(_ token: UInt32) {
        lock.withLock {
            if _held.remove(token) != nil { _releaseCount += 1 }
        }
    }
}

/// Backend that always fails to acquire, to test the failure path.
struct FailingKeepAwake: KeepAwakeAsserting {
    func acquire(reason: String) -> UInt32 { 0 }
    func release(_ token: UInt32) {}
}

/// A one-shot gate that makes injected timed-expiry deterministic: the manager
/// suspends in `wait()` until the test calls `open()`.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for w in pending { w.resume() }
    }
}

// MARK: - Suite

@MainActor
struct CaffeineManagerTests {

    // --- State machine (deterministic, fake backend) ---

    @Test func initiallyInactiveHoldsNothing() {
        let fake = FakeKeepAwake()
        let m = CaffeineManager(backend: fake)
        #expect(m.active == false)
        #expect(m.expiresAt == nil)
        #expect(fake.acquireCount == 0)
        #expect(fake.heldCount == 0)
    }

    @Test func activateIndefiniteHoldsExactlyOne() {
        let fake = FakeKeepAwake()
        let m = CaffeineManager(backend: fake)
        m.activate()
        #expect(m.active)
        #expect(m.expiresAt == nil, "indefinite session has no expiry")
        #expect(fake.acquireCount == 1)
        #expect(fake.heldCount == 1)
    }

    @Test func activateIsIdempotent() {
        let fake = FakeKeepAwake()
        let m = CaffeineManager(backend: fake)
        m.activate(); m.activate(); m.activate()
        #expect(m.active)
        #expect(fake.acquireCount == 1, "must not stack assertions")
        #expect(fake.heldCount == 1)
    }

    @Test func deactivateReleases() {
        let fake = FakeKeepAwake()
        let m = CaffeineManager(backend: fake)
        m.activate()
        m.deactivate()
        #expect(m.active == false)
        #expect(m.expiresAt == nil)
        #expect(fake.releaseCount == 1)
        #expect(fake.heldCount == 0)
    }

    @Test func deactivateWhenInactiveIsNoOp() {
        let fake = FakeKeepAwake()
        let m = CaffeineManager(backend: fake)
        m.deactivate()
        #expect(m.active == false)
        #expect(fake.acquireCount == 0)
        #expect(fake.releaseCount == 0)
    }

    @Test func toggleFlipsState() {
        let fake = FakeKeepAwake()
        let m = CaffeineManager(backend: fake)
        m.toggle()
        #expect(m.active)
        #expect(fake.heldCount == 1)
        m.toggle()
        #expect(m.active == false)
        #expect(fake.heldCount == 0)
    }

    @Test func timedActivateSetsExpiryInFuture() throws {
        let fake = FakeKeepAwake()
        let m = CaffeineManager(backend: fake)
        let before = Date()
        m.activate(.hour1)
        #expect(m.active)
        let expires = try #require(m.expiresAt)
        // ~1 hour out, within a wide tolerance.
        #expect(abs(expires.timeIntervalSince(before) - 3600) < 5)
        #expect(fake.heldCount == 1)
    }

    @Test func reArmUpdatesExpiryWithoutStackingAssertions() throws {
        let fake = FakeKeepAwake()
        let m = CaffeineManager(backend: fake)
        m.activate(.min30)
        let first = try #require(m.expiresAt)
        m.activate(.hours5)
        #expect(fake.acquireCount == 1, "re-arming must reuse the single assertion")
        #expect(fake.heldCount == 1)
        let second = try #require(m.expiresAt)
        #expect(second > first, "5h expiry should be later than 30m")
    }

    @Test func manyCyclesBalanceHolds() {
        let fake = FakeKeepAwake()
        let m = CaffeineManager(backend: fake)
        for _ in 0..<1_000 { m.activate(); m.deactivate() }
        #expect(m.active == false)
        #expect(fake.acquireCount == 1_000)
        #expect(fake.releaseCount == 1_000)
        #expect(fake.heldCount == 0, "no leaked assertions")
    }

    @Test func acquireFailureLeavesInactive() {
        let m = CaffeineManager(backend: FailingKeepAwake())
        m.activate()
        #expect(m.active == false, "must not report active when the assertion couldn't be held")
        #expect(m.expiresAt == nil)
    }

    // --- Timed expiry (deterministic via injected gate) ---

    @Test func timedExpiryReleasesAssertion() async {
        let fake = FakeKeepAwake()
        let gate = Gate()
        let m = CaffeineManager(backend: fake, sleepFor: { _ in await gate.wait() })
        m.activate(.min30)
        #expect(m.active)
        #expect(fake.heldCount == 1)

        await gate.open()                       // "timer" fires
        await waitUntil { !m.active }           // expiry task hops back to main actor

        #expect(m.active == false)
        #expect(m.expiresAt == nil)
        #expect(fake.heldCount == 0)
    }

    @Test func deactivateCancelsPendingExpiry() async {
        let fake = FakeKeepAwake()
        let gate = Gate()
        let m = CaffeineManager(backend: fake, sleepFor: { _ in await gate.wait() })
        m.activate(.min30)
        m.deactivate()                          // cancels the expiry task
        #expect(fake.heldCount == 0)

        await gate.open()                       // cancelled task wakes…
        await Task.yield()
        // …and its `guard !Task.isCancelled` must prevent a second release.
        #expect(m.active == false)
        #expect(fake.releaseCount == 1, "expiry must not release twice")
        #expect(fake.heldCount == 0)
    }

    // --- Integration: the real OS assertion ---

    /// Proves the production `IOKitKeepAwake` backend registers a real
    /// `PreventUserIdleDisplaySleep` assertion the system can see, and clears it on
    /// release. Silently passes if this environment can't create assertions at all.
    @Test func realBackendRegistersAndClearsSystemAssertion() {
        let reason = "BattlifyKitTest-\(UUID().uuidString)"
        let m = CaffeineManager(backend: IOKitKeepAwake(), reason: reason)

        m.activate()
        guard m.active else { return }   // assertions unavailable → nothing to prove
        #expect(Self.processHoldsAssertion(named: reason),
                "system should report our display-sleep assertion while active")

        m.deactivate()
        #expect(Self.processHoldsAssertion(named: reason) == false,
                "assertion should be gone after deactivate")
    }

    // --- Benchmarks ---

    /// Benchmark: pure toggle throughput (fake backend, no OS calls). Prints ns/op
    /// and trips only on a gross regression.
    @Test func benchmarkToggleThroughput() {
        let fake = FakeKeepAwake()
        let m = CaffeineManager(backend: fake)
        let iterations = 100_000
        let elapsed = ContinuousClock().measure {
            for _ in 0..<iterations { m.activate(); m.deactivate() }
        }
        let nsPerOp = Double(elapsed.components.attoseconds) / 1e9 / Double(iterations)
        print("BENCHMARK toggle-throughput: \(iterations) activate+deactivate in \(elapsed) (~\(String(format: "%.0f", nsPerOp)) ns/op)")
        #expect(fake.heldCount == 0)
        #expect(elapsed < .seconds(5), "gross toggle-throughput regression")
    }

    /// Benchmark: real IOKit assertion acquire/release round-trips — the per-toggle OS
    /// cost, so a regression there is visible. No-op if assertions are unavailable.
    @Test func benchmarkRealAssertionCycle() {
        let m = CaffeineManager(backend: IOKitKeepAwake())
        m.activate(); let ok = m.active; m.deactivate()
        guard ok else { return }
        let iterations = 500
        let elapsed = ContinuousClock().measure {
            for _ in 0..<iterations { m.activate(); m.deactivate() }
        }
        let usPerOp = Double(elapsed.components.attoseconds) / 1e12 / Double(iterations)
        print("BENCHMARK real-IOKit-cycle: \(iterations) acquire+release in \(elapsed) (~\(String(format: "%.1f", usPerOp)) µs/op)")
    }

    // --- Helpers ---

    /// Poll main-actor state until `cond` holds (bounded), for async expiry hops.
    private func waitUntil(_ cond: () -> Bool, tries: Int = 500) async {
        var n = 0
        while !cond() && n < tries { await Task.yield(); n += 1 }
    }

    /// True if *this* process currently holds a power assertion with the given name.
    nonisolated static func processHoldsAssertion(named name: String) -> Bool {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
              let byPID = out?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return false }
        let mine = byPID[NSNumber(value: getpid())] ?? []
        return mine.contains { ($0[kIOPMAssertionNameKey as String] as? String) == name }
    }
}
