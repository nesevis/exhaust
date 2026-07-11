import ExhaustCore
import Testing

@Suite("FaultInventory clustering tests")
struct FaultInventoryTests {
    @Test("Distinct reduced forms create distinct clusters despite identical symptoms")
    func slippageSeparation() {
        let inventory = FaultInventory()
        let first = inventory.recordReduced(
            reducedSequence: sequence(length: 1),
            reducedKey: "A",
            renderDescription: { "A" },
            signature: signature(edges: [1]),
            symptom: FailureSymptom(kind: "ParserError"),
            phase: .sprawl,
            timestampNanoseconds: 10,
            attemptIndex: 1
        )
        let second = inventory.recordReduced(
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
        let clusters = inventory.snapshot()
        #expect(clusters.count == 2)
    }

    @Test("Identical reduced form with a different signature stays one cluster with two signatures")
    func likelySameTier() {
        let inventory = FaultInventory()
        _ = inventory.recordReduced(
            reducedSequence: sequence(length: 1),
            reducedKey: "A",
            renderDescription: { "A" },
            signature: signature(edges: [1, 2]),
            symptom: .returnedFalse,
            phase: .sampling,
            timestampNanoseconds: 10,
            attemptIndex: 1
        )
        let second = inventory.recordReduced(
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
        let clusters = inventory.snapshot()
        #expect(clusters.count == 1)
        #expect(clusters[0].signatures.count == 2)
        #expect(clusters[0].discoveringPhase == .sampling)
        #expect(clusters[0].firstSeenNanoseconds == 10)
        #expect(clusters[0].lastSeenNanoseconds == 20)
    }

    @Test("Identical reduced form and signature merges without signature growth")
    func sameClusterTier() {
        let inventory = FaultInventory()
        for timestamp in [10, 20, 30] as [UInt64] {
            _ = inventory.recordReduced(
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
        let clusters = inventory.snapshot()
        #expect(clusters.count == 1)
        #expect(clusters[0].signatures.count == 1)
        #expect(clusters[0].instanceCount == 3)
        #expect(clusters[0].reducedCount == 3)
    }

    @Test("Cap reporting reflects the per-cluster reduction cap")
    func capReached() {
        let inventory = FaultInventory()
        var lastClassification: ClusterClassification?
        for index in 0 ..< SprawlTunables.perClusterReductionCap {
            lastClassification = inventory.recordReduced(
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
    func unreducedAttribution() {
        let inventory = FaultInventory()
        _ = inventory.recordReduced(
            reducedSequence: sequence(length: 1),
            reducedKey: "A",
            renderDescription: { "A" },
            signature: nil,
            symptom: FailureSymptom(kind: "ParserError"),
            phase: .sprawl,
            timestampNanoseconds: 10,
            attemptIndex: 1
        )
        inventory.recordUnreduced(
            symptom: FailureSymptom(kind: "ParserError"),
            timestampNanoseconds: 20,
            attemptIndex: 2
        )
        inventory.recordUnreduced(
            symptom: FailureSymptom(kind: "OtherError"),
            timestampNanoseconds: 30,
            attemptIndex: 3
        )
        let clusters = inventory.snapshot()
        #expect(clusters[0].instanceCount == 2)
        #expect(clusters[0].reducedCount == 1)
        let unmatched = inventory.unmatchedUnreducedCounts
        #expect(unmatched[FailureSymptom(kind: "OtherError")] == 1)
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
