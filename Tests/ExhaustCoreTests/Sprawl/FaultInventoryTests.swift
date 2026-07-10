import ExhaustCore
import Testing

@Suite("FaultInventory clustering tests")
struct FaultInventoryTests {
    @Test("Distinct reduced forms create distinct clusters despite identical symptoms")
    func slippageSeparation() async {
        let inventory = FaultInventory()
        let first = await inventory.recordReduced(
            reducedSequence: sequence(length: 1),
            reducedDescription: "A",
            signature: signature(edges: [1]),
            symptom: FailureSymptom(kind: "ParserError"),
            phase: .sprawl,
            timestampNanoseconds: 10
        )
        let second = await inventory.recordReduced(
            reducedSequence: sequence(length: 2),
            reducedDescription: "B",
            signature: signature(edges: [1]),
            symptom: FailureSymptom(kind: "ParserError"),
            phase: .sprawl,
            timestampNanoseconds: 20
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
            reducedDescription: "A",
            signature: signature(edges: [1, 2]),
            symptom: .returnedFalse,
            phase: .sampling,
            timestampNanoseconds: 10
        )
        let second = await inventory.recordReduced(
            reducedSequence: sequence(length: 1),
            reducedDescription: "A",
            signature: signature(edges: [1, 3]),
            symptom: .returnedFalse,
            phase: .sprawl,
            timestampNanoseconds: 20
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
                reducedDescription: "A",
                signature: signature(edges: [1, 2]),
                symptom: .returnedFalse,
                phase: .sprawl,
                timestampNanoseconds: timestamp
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
                reducedDescription: "A",
                signature: nil,
                symptom: .returnedFalse,
                phase: .sprawl,
                timestampNanoseconds: UInt64(index)
            )
        }
        #expect(lastClassification?.capReached == true)
    }

    @Test("Unreduced failures attribute to the symptom-matched cluster or hold unmatched")
    func unreducedAttribution() async {
        let inventory = FaultInventory()
        _ = await inventory.recordReduced(
            reducedSequence: sequence(length: 1),
            reducedDescription: "A",
            signature: nil,
            symptom: FailureSymptom(kind: "ParserError"),
            phase: .sprawl,
            timestampNanoseconds: 10
        )
        await inventory.recordUnreduced(
            symptom: FailureSymptom(kind: "ParserError"),
            timestampNanoseconds: 20
        )
        await inventory.recordUnreduced(
            symptom: FailureSymptom(kind: "OtherError"),
            timestampNanoseconds: 30
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
        #expect(gate.admit(sequenceHash: 42, symptom: .returnedFalse) == .reduce)
        #expect(gate.admit(sequenceHash: 42, symptom: .returnedFalse) == .duplicate)
    }

    @Test("Per-symptom cap stops dispatch with a periodic escape hatch")
    func capAndEscape() {
        var gate = ReductionGate()
        var hash: UInt64 = 0
        var verdicts: [ReductionGate.Verdict] = []
        // Run enough distinct failures of one symptom to pass the cap and reach the escape interval.
        for _ in 0 ..< (SprawlTunables.reductionEscapeInterval * 2) {
            hash += 1
            verdicts.append(gate.admit(sequenceHash: hash, symptom: .returnedFalse))
        }
        let reduceCount = verdicts.count(where: { $0 == .reduce })
        let capped = verdicts.count(where: { $0 == .recordUnreduced })
        // Cap admissions plus two escape-interval admissions.
        #expect(reduceCount == SprawlTunables.perClusterReductionCap + 2)
        #expect(capped == verdicts.count - reduceCount)

        // A different symptom has its own budget.
        #expect(gate.admit(sequenceHash: hash + 1, symptom: FailureSymptom(kind: "Other")) == .reduce)
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
