import ExhaustCore
import Testing
@testable import Exhaust

@Suite("Fault inventory restore and symptom attribution")
struct FaultInventoryRestoreTests {
    @Test("Folding restored clusters preserves counts and yields unique keys with contiguous identifiers")
    func foldIsConservative() throws {
        try #exhaust(#gen(.int(in: 0 ... 5).array(length: 1 ... 8))) { keyIndices in
            let restored = keyIndices.enumerated().map { position, keyIndex in
                cluster(id: position, key: "k\(keyIndex)", instances: position + 1, symptom: "s\(keyIndex)")
            }
            let inventory = FaultInventory()
            inventory.restore(clusters: restored)
            let folded = inventory.snapshot()

            // Nothing is invented and nothing is dropped: the fold is a regrouping of the same members.
            #expect(folded.reduce(0) { $0 + $1.instanceCount } == restored.reduce(0) { $0 + $1.instanceCount })
            #expect(folded.reduce(0) { $0 + $1.reducedCount } == restored.reduce(0) { $0 + $1.reducedCount })
            #expect(Set(folded.map(\.reducedKey)) == Set(restored.map(\.reducedKey)))
            #expect(folded.count == Set(restored.map(\.reducedKey)).count)
            // Contiguous from zero, because recordReduced allocates the next identifier from the count.
            #expect(folded.map(\.id) == Array(folded.indices))
            // The survivor keeps the earliest member's discovery, whichever duplicate it came from.
            for group in Dictionary(grouping: restored, by: \.reducedKey) {
                let survivor = try #require(folded.first { $0.reducedKey == group.key })
                #expect(survivor.firstSeenAttempt == group.value.map(\.firstSeenAttempt).min())
                #expect(survivor.lastSeenNanoseconds == group.value.map(\.lastSeenNanoseconds).max())
                #expect(survivor.symptoms == Set(group.value.flatMap(\.symptoms)))
            }
        }
    }

    @Test("Symptom attribution picks the same cluster the linear scan did")
    func attributionMatchesTheScan() throws {
        try #exhaust(#gen(.int(in: 0 ... 3).array(length: 1 ... 6))) { symptomIndices in
            let restored = symptomIndices.enumerated().map { position, symptomIndex in
                cluster(
                    id: position,
                    key: "k\(position)",
                    instances: 1,
                    symptom: "s\(symptomIndex)",
                    lastSeen: UInt64(symptomIndices.count - position)
                )
            }
            let inventory = FaultInventory()
            inventory.restore(clusters: restored)

            for symptomIndex in Set(symptomIndices).sorted() {
                let symptom = FailureSymptom(kind: "s\(symptomIndex)")
                // Snapshot per attribution: each one bumps a cluster's instance count, so the comparison has to be against the state that call actually saw.
                let before = inventory.snapshot()
                // The rule the linear scan applied: among clusters carrying the symptom, the greatest lastSeen, ties to the lowest index.
                let expected = before.indices
                    .filter { before[$0].symptoms.contains(symptom) }
                    .max { before[$0].lastSeenNanoseconds < before[$1].lastSeenNanoseconds }
                inventory.recordUnreduced(symptom: symptom, timestampNanoseconds: 0, attemptIndex: 0)
                let after = inventory.snapshot()
                let moved = after.indices.filter { after[$0].instanceCount != before[$0].instanceCount }
                #expect(moved == [expected].compactMap { $0 })
                #expect(inventory.unmatchedUnreducedCounts.isEmpty)
            }
        }
    }

    @Test("A symptom no cluster carries is held unmatched")
    func unmatchedSymptom() {
        let inventory = FaultInventory()
        inventory.restore(clusters: [cluster(id: 0, key: "k", instances: 1, symptom: "a")])
        inventory.recordUnreduced(symptom: FailureSymptom(kind: "b"), timestampNanoseconds: 1, attemptIndex: 1)
        #expect(inventory.unmatchedUnreducedCounts[FailureSymptom(kind: "b")] == 1)
        #expect(inventory.snapshot()[0].instanceCount == 1)
    }
}

// MARK: - Helpers

private func cluster(
    id: Int,
    key: String,
    instances: Int,
    symptom: String,
    lastSeen: UInt64 = 0
) -> FaultCluster {
    FaultCluster(
        restoredID: id,
        reducedSequence: [],
        reducedDescription: key,
        reducedKey: key,
        signatures: [],
        symptoms: [FailureSymptom(kind: symptom)],
        instanceCount: instances,
        reducedCount: 1,
        firstSeenNanoseconds: UInt64(id),
        lastSeenNanoseconds: lastSeen,
        firstSeenAttempt: id + 1,
        unnormalizedMemberCount: 0,
        discoveringPhase: .mutation
    )
}
