import ExhaustCore
import Testing

@Suite("FaultInventory clustering tests")
struct FaultInventoryTests {
    @Test("Distinct reduced forms create distinct clusters despite identical symptoms")
    func slippageSeparation() async {
        let inventory = FaultInventory()
        let first = await inventory.recordReduced(
            reducedSequence: sequence(length: 1),
            reducedKey: "A",
            renderDescription: { "A" },
            signature: signature(edges: [1]),
            symptom: FailureSymptom(kind: "ParserError"),
            phase: .sprawl,
            timestampNanoseconds: 10,
            attemptIndex: 1
        )
        let second = await inventory.recordReduced(
            reducedSequence: sequence(length: 2),
            reducedKey: "B",
            renderDescription: { "B" },
            signature: signature(edges: [1]),
            symptom: FailureSymptom(kind: "ParserError"),
            phase: .sprawl,
            timestampNanoseconds: 20,
            attemptIndex: 2
        )
        #expect(first.isNewCluster)
        #expect(second.isNewCluster)
        #expect(first.clusterID != second.clusterID)
        let clusters = await inventory.snapshot()
        #expect(clusters.count == 2)
    }

    @Test("Identical reduced form with a different signature stays one cluster with two signatures")
    func likelySameTier() async {
        let inventory = FaultInventory()
        _ = await inventory.recordReduced(
            reducedSequence: sequence(length: 1),
            reducedKey: "A",
            renderDescription: { "A" },
            signature: signature(edges: [1, 2]),
            symptom: .returnedFalse,
            phase: .sampling,
            timestampNanoseconds: 10,
            attemptIndex: 1
        )
        let second = await inventory.recordReduced(
            reducedSequence: sequence(length: 1),
            reducedKey: "A",
            renderDescription: { "A" },
            signature: signature(edges: [1, 3]),
            symptom: .returnedFalse,
            phase: .sprawl,
            timestampNanoseconds: 20,
            attemptIndex: 2
        )
        #expect(second.isNewCluster == false)
        #expect(second.instanceCount == 2)
        let clusters = await inventory.snapshot()
        #expect(clusters.count == 1)
        #expect(clusters[0].signatures.count == 2)
        #expect(clusters[0].discoveringPhase == .sampling)
        #expect(clusters[0].firstSeenNanoseconds == 10)
        #expect(clusters[0].lastSeenNanoseconds == 20)
    }

    @Test("Identical reduced form and signature merges without signature growth")
    func sameClusterTier() async {
        let inventory = FaultInventory()
        for timestamp in [10, 20, 30] as [UInt64] {
            _ = await inventory.recordReduced(
                reducedSequence: sequence(length: 1),
                reducedKey: "A",
                renderDescription: { "A" },
                signature: signature(edges: [1, 2]),
                symptom: .returnedFalse,
                phase: .sprawl,
                timestampNanoseconds: timestamp,
                attemptIndex: Int(timestamp)
            )
        }
        let clusters = await inventory.snapshot()
        #expect(clusters.count == 1)
        #expect(clusters[0].signatures.count == 1)
        #expect(clusters[0].instanceCount == 3)
        #expect(clusters[0].reducedCount == 3)
    }

    @Test("Cap reporting reflects the per-cluster reduction cap")
    func capReached() async {
        let inventory = FaultInventory()
        var lastClassification: ClusterClassification?
        for index in 0 ..< SprawlTunables.perClusterReductionCap {
            lastClassification = await inventory.recordReduced(
                reducedSequence: sequence(length: 1),
                reducedKey: "A",
                renderDescription: { "A" },
                signature: nil,
                symptom: .returnedFalse,
                phase: .sprawl,
                timestampNanoseconds: UInt64(index),
                attemptIndex: index + 1
            )
        }
        #expect(lastClassification?.capReached == true)
    }

    @Test("Unreduced failures attribute to the symptom-matched cluster or hold unmatched")
    func unreducedAttribution() async {
        let inventory = FaultInventory()
        _ = await inventory.recordReduced(
            reducedSequence: sequence(length: 1),
            reducedKey: "A",
            renderDescription: { "A" },
            signature: nil,
            symptom: FailureSymptom(kind: "ParserError"),
            phase: .sprawl,
            timestampNanoseconds: 10,
            attemptIndex: 1
        )
        await inventory.recordUnreduced(
            symptom: FailureSymptom(kind: "ParserError"),
            timestampNanoseconds: 20,
            attemptIndex: 2
        )
        await inventory.recordUnreduced(
            symptom: FailureSymptom(kind: "OtherError"),
            timestampNanoseconds: 30,
            attemptIndex: 3
        )
        let clusters = await inventory.snapshot()
        #expect(clusters[0].instanceCount == 2)
        #expect(clusters[0].reducedCount == 1)
        let unmatched = await inventory.unmatchedUnreducedCounts
        #expect(unmatched[FailureSymptom(kind: "OtherError")] == 1)
    }
}

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

@Suite("ReductionPool bounded concurrency tests")
struct ReductionPoolTests {
    @Test("All submitted work completes and drain waits for it")
    func drainCompletes() async {
        let pool = ReductionPool(maxConcurrent: 2)
        let counter = Counter()
        for _ in 0 ..< 20 {
            pool.submit {
                await counter.increment()
            }
        }
        #expect(pool.drain(timeoutNanoseconds: 5_000_000_000))
        #expect(await counter.value == 20)
    }

    @Test("Concurrency never exceeds the cap")
    func concurrencyBounded() async {
        let pool = ReductionPool(maxConcurrent: 3)
        let tracker = ConcurrencyTracker()
        for _ in 0 ..< 30 {
            pool.submit {
                await tracker.enter()
                try? await Task.sleep(nanoseconds: 1_000_000)
                await tracker.exit()
            }
        }
        #expect(pool.drain(timeoutNanoseconds: 5_000_000_000))
        #expect(await tracker.peak <= 3)
        #expect(await tracker.total == 30)
    }

    @Test("Drain on an idle pool returns immediately")
    func drainIdle() {
        let pool = ReductionPool(maxConcurrent: 2)
        #expect(pool.drain(timeoutNanoseconds: 1_000_000))
    }

    @Test("Drain times out while work is still running")
    func drainTimeout() {
        let pool = ReductionPool(maxConcurrent: 1)
        pool.submit {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(pool.drain(timeoutNanoseconds: 1_000_000) == false)
        #expect(pool.drain(timeoutNanoseconds: 5_000_000_000))
    }
}

// MARK: - Helpers

private func sequence(length: Int) -> ChoiceSequence {
    ChoiceSequence(repeating: .just, count: length)
}

private func signature(edges: [Int]) -> BitSet {
    var bitSet = BitSet(capacity: 16)
    for edge in edges {
        bitSet.insert(edge)
    }
    return bitSet
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0
    private(set) var total = 0

    func enter() {
        current += 1
        peak = max(peak, current)
        total += 1
    }

    func exit() {
        current -= 1
    }
}
