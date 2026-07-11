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

    @Test("Per-symptom cap stops dispatch with a periodic escape hatch")
    func capAndEscape() {
        // The fixed every-K-th cadence under test is the legacy path; the adaptive default is covered by escapeBackoffArithmetic.
        var experiments = SprawlExperiments()
        experiments.escapeBackoff = false
        var gate = ReductionGate(experiments: experiments)
        var hash: UInt64 = 0
        var verdicts: [ReductionGate.Verdict] = []
        // Run enough distinct failures of one symptom to pass the cap and reach the escape interval.
        for _ in 0 ..< (SprawlTunables.reductionEscapeInterval * 2) {
            hash += 1
            verdicts.append(gate.admit(sequenceHash: hash, symptom: .returnedFalse))
        }
        let reduceCount = verdicts.count(where: { verdict in
            if case .reduce = verdict {
                return true
            }
            return false
        })
        let escapeCount = verdicts.count(where: { $0 == .reduce(escape: true) })
        let capped = verdicts.count(where: { $0 == .recordUnreduced })
        // Cap admissions plus two escape-interval admissions.
        #expect(reduceCount == SprawlTunables.perClusterReductionCap + 2)
        #expect(escapeCount == 2)
        #expect(capped == verdicts.count - reduceCount)

        // A different symptom has its own budget.
        #expect(gate.admit(sequenceHash: hash + 1, symptom: FailureSymptom(kind: "Other")) == .reduce(escape: false))
    }

    @Test("Adaptive escape interval widens on existing-cluster escapes and resets on a new cluster")
    func escapeBackoffArithmetic() {
        var experiments = SprawlExperiments()
        experiments.escapeBackoff = true
        var gate = ReductionGate(experiments: experiments)
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
        for _ in 0 ..< SprawlTunables.perClusterReductionCap {
            hash += 1
            #expect(gate.admit(sequenceHash: hash, symptom: symptom) == .reduce(escape: false))
        }

        // The first escape arrives one base interval after the first capped failure.
        let base = SprawlTunables.reductionEscapeInterval
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
        #expect(failuresUntilEscape(limit: SprawlTunables.reductionEscapeIntervalCap + 1) == SprawlTunables.reductionEscapeIntervalCap)
    }

    @Test("The legacy fixed interval is untouched when the experiment is off")
    func escapeBackoffOffPreservesLegacyCadence() {
        var experiments = SprawlExperiments()
        experiments.escapeBackoff = false
        var gate = ReductionGate(experiments: experiments)
        var hash: UInt64 = 0
        var verdicts: [ReductionGate.Verdict] = []
        for _ in 0 ..< (SprawlTunables.reductionEscapeInterval * 2) {
            hash += 1
            verdicts.append(gate.admit(sequenceHash: hash, symptom: .returnedFalse))
        }
        // noteEscapeOutcome is a no-op with the knob off; the cadence stays every K-th seen failure.
        gate.noteEscapeOutcome(symptom: .returnedFalse, isNewCluster: false)
        hash += 1
        var followUp: [ReductionGate.Verdict] = []
        for _ in 0 ..< SprawlTunables.reductionEscapeInterval {
            hash += 1
            followUp.append(gate.admit(sequenceHash: hash, symptom: .returnedFalse))
        }
        #expect(verdicts.count(where: { $0 == .reduce(escape: true) }) == 2)
        #expect(followUp.count(where: { $0 == .reduce(escape: true) }) == 1)
    }
}
