import ExhaustCore
import Testing

@Suite("ReductionGate backpressure tests")
struct ReductionGateTests {
    @Test("Duplicate sequence hashes are dropped")
    func duplicateDrop() {
        var gate = ReductionGate()
        #expect(gate.admit(sequenceHash: 42, symptom: .returnedFalse) == .reduce(escape: false))
        #expect(gate.admit(sequenceHash: 42, symptom: .returnedFalse) == .duplicate)
    }

    @Test("Adaptive escape interval widens on existing-cluster escapes and resets on a new cluster")
    func escapeBackoffArithmetic() {
        var gate = ReductionGate()
        var hash: UInt64 = 0
        let symptom = FailureSymptom.returnedFalse

        func failuresUntilEscape(limit: Int) -> Int? {
            for count in 1 ... limit {
                hash += 1
                if gate.admit(sequenceHash: hash, symptom: symptom) == .reduce(escape: true) {
                    return count
                }
            }
            return nil
        }

        // Fill the cap; none of these are escapes.
        for _ in 0 ..< FuzzTunables.perClusterReductionCap {
            hash += 1
            #expect(gate.admit(sequenceHash: hash, symptom: symptom) == .reduce(escape: false))
        }

        // The first escape arrives one base interval after the first capped failure.
        let base = FuzzTunables.reductionEscapeInterval
        #expect(failuresUntilEscape(limit: base + 1) == base + 1)

        // An escape that joined an existing cluster doubles the interval.
        gate.noteEscapeOutcome(symptom: symptom, isNewCluster: false)
        #expect(failuresUntilEscape(limit: base * 2 + 1) == base * 2)

        // A new-cluster escape resets the interval to the base.
        gate.noteEscapeOutcome(symptom: symptom, isNewCluster: true)
        #expect(failuresUntilEscape(limit: base * 2) == base)

        // Repeated widenings never exceed the cap.
        for _ in 0 ..< 32 {
            gate.noteEscapeOutcome(symptom: symptom, isNewCluster: false)
        }
        #expect(failuresUntilEscape(limit: FuzzTunables.reductionEscapeIntervalCap + 1) == FuzzTunables.reductionEscapeIntervalCap)
    }
}
