import Testing
@testable import ExhaustCore

@Suite("BoundValueGate")
struct BoundValueGateTests {

    private static let tuning = SchedulerTuning()

    // MARK: - Fresh Gate

    @Test("Fresh gate returns classifyFirst for unknown fingerprint")
    func freshGateClassifiesFirst() {
        let gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        let decision = gate.shouldDispatch(fingerprint: 0xAAAA, anyAcceptedThisCycle: false)
        #expect(decision == .classifyFirst)
    }

    // MARK: - Per-Cycle Dedup

    @Test("Same fingerprint dispatched twice in one cycle is skipped")
    func perCycleDedup() {
        var gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        gate.markDispatched(0xBBBB)
        let decision = gate.shouldDispatch(fingerprint: 0xBBBB, anyAcceptedThisCycle: false)
        #expect(decision == .skip)
    }

    @Test("Cycle reset clears per-cycle dedup")
    func cycleResetClearsDedup() {
        var gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        gate.markDispatched(0xCCCC)
        gate.resetForNewCycle()
        let decision = gate.shouldDispatch(fingerprint: 0xCCCC, anyAcceptedThisCycle: false)
        #expect(decision == .classifyFirst)
    }

    // MARK: - Acceptance Deferral

    @Test("Any prior acceptance this cycle causes skip")
    func acceptanceDeferral() {
        let gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        let decision = gate.shouldDispatch(fingerprint: 0xDDDD, anyAcceptedThisCycle: true)
        #expect(decision == .skip)
    }

    // MARK: - Fruitless Tracking

    @Test("Fruitless fingerprint is skipped")
    func fruitlessSkipped() {
        var gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        gate.markFruitless(0xEEEE)
        let decision = gate.shouldDispatch(fingerprint: 0xEEEE, anyAcceptedThisCycle: false)
        #expect(decision == .skip)
    }

    @Test("Accepted outcome clears fruitless status")
    func acceptedClearsFruitless() {
        var gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        gate.markFruitless(0xFFFF)
        gate.recordOutcome(fingerprint: 0xFFFF, accepted: true)
        let decision = gate.shouldDispatch(fingerprint: 0xFFFF, anyAcceptedThisCycle: false)
        #expect(decision == .classifyFirst)
    }

    @Test("Rejected outcome marks fruitless")
    func rejectedMarksFruitless() {
        var gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        gate.recordOutcome(fingerprint: 0x1111, accepted: false)
        let decision = gate.shouldDispatch(fingerprint: 0x1111, anyAcceptedThisCycle: false)
        #expect(decision == .skip)
    }

    // MARK: - Exponential Decay

    @Test("Decayed budget halves per stall", arguments: 0 ... 5)
    func decayHalvesPerStall(stalls: Int) {
        var gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        let fingerprint: UInt64 = 0x2222
        for _ in 0 ..< stalls {
            gate.recordOutcome(fingerprint: fingerprint, accepted: false)
        }
        let budget = gate.decayedBudget(fingerprint: fingerprint)
        let baseBudget = Self.tuning.boundValueBaseBudget
        #expect(budget == max(1, baseBudget >> stalls))
    }

    @Test("Custom base budget is respected", arguments: 0 ... 4)
    func customBaseBudget(stalls: Int) {
        var gate = BoundValueGate(baseBudget: 30)
        let fingerprint: UInt64 = 0x3333
        for _ in 0 ..< stalls {
            gate.recordOutcome(fingerprint: fingerprint, accepted: false)
        }
        let budget = gate.decayedBudget(fingerprint: fingerprint)
        #expect(budget == max(1, 30 >> stalls))
    }

    @Test("Accepted outcome resets stall count and restores full budget")
    func acceptedResetsStallCount() {
        let baseBudget = Self.tuning.boundValueBaseBudget
        var gate = BoundValueGate(baseBudget: baseBudget)
        let fingerprint: UInt64 = 0x4444
        gate.recordOutcome(fingerprint: fingerprint, accepted: false)
        gate.recordOutcome(fingerprint: fingerprint, accepted: false)
        gate.recordOutcome(fingerprint: fingerprint, accepted: false)
        #expect(gate.decayedBudget(fingerprint: fingerprint) == max(1, baseBudget >> 3))

        gate.recordOutcome(fingerprint: fingerprint, accepted: true)
        #expect(gate.decayedBudget(fingerprint: fingerprint) == baseBudget)
    }

    @Test("Budget floors at 1 for high stall counts")
    func budgetFloor() {
        var gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        let fingerprint: UInt64 = 0x5555
        for _ in 0 ..< 20 {
            gate.recordOutcome(fingerprint: fingerprint, accepted: false)
        }
        #expect(gate.decayedBudget(fingerprint: fingerprint) == 1)
    }

    // MARK: - Decision Priority

    @Test("Per-cycle dedup takes precedence over acceptance deferral")
    func dedupPrecedesAcceptanceDeferral() {
        var gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        gate.markDispatched(0x6666)
        let decision = gate.shouldDispatch(fingerprint: 0x6666, anyAcceptedThisCycle: true)
        #expect(decision == .skip)
    }
}
