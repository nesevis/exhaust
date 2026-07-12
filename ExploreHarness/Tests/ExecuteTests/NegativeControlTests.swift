import ExecuteFixture
import Exhaust
import Testing

@Suite("Negative control: gradient-free latch", .serialized)
struct NegativeControlTests {
    // MARK: - Reproducer Smoke Tests

    @Test("Fault N fires on 10 consecutive arming pulses")
    func faultNMinimal() {
        var latch = ConsecutiveLatch()
        for _ in 0 ..< 10 {
            latch.pulse(7)
        }
        #expect(latch.isTripped, "10 consecutive pulse(7) calls should trip the latch")
    }

    @Test("Fault N does not fire on 9 consecutive arming pulses (strict prefix)")
    func faultNPrefixSafe() {
        var latch = ConsecutiveLatch()
        for _ in 0 ..< 9 {
            latch.pulse(7)
        }
        #expect(latch.isTripped == false, "9 consecutive pulses are below the threshold")
    }

    @Test("Fault N does not fire when a non-arming pulse interrupts the streak")
    func faultNResetByOtherDigit() {
        var latch = ConsecutiveLatch()
        for _ in 0 ..< 9 {
            latch.pulse(7)
        }
        latch.pulse(3)
        for _ in 0 ..< 9 {
            latch.pulse(7)
        }
        #expect(latch.isTripped == false, "a non-7 pulse resets the streak; 9 + 9 never reaches 10")
    }

    // MARK: - The Negative Control

    @Test("The latch fault is not found at matched budget")
    func gradientFreeLatchNotFound() async {
        // A pre-registered differential target, not a capability claim: this test FAILING after a new feedback channel lands (spec-state feedback, value profile) is that channel's gate passing. Until then it documents that edge coverage alone does not ladder streak-gated state. The pinned seed makes the run deterministic; the unpinned miss probability is ~3.1e-9 per attempt (see the fixture header).
        let report = await #execute(
            ConsecutiveLatchSpec.self,
            time: .seconds(5),
            .commandLimit(40),
            .replay(1),
            .suppress(.issueReporting)
        )
        #expect(report.totalAttempts > 0)
        #expect(report.clusters.isEmpty, "The gradient-free latch was found — a feedback channel now ladders streak-gated state. Move this fixture into that channel's differential gate and update fuzzer-selftest-sut-landscape.md.")
    }
}

// MARK: - Spec

/// Twin of BenchmarkLatchSpec in ExploreBenchmark.swift: the specFeatures gate must measure the same spec this negative control pins, and the two targets cannot share the class because @StateMachine synthesis is module-internal. Change both or neither.
@StateMachine(.sequential)
final class ConsecutiveLatchSpec {
    @SystemUnderTest var latch: ConsecutiveLatch = .init()

    @Invariant
    func neverTripped() -> Bool {
        latch.isTripped == false
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func pulse(digit: Int) throws {
        latch.pulse(digit)
    }

    func failureDescription() -> String? {
        "\(latch)"
    }
}
