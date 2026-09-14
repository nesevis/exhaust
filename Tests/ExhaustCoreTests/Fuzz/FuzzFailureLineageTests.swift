import Foundation
import Testing
@testable import ExhaustCore

@Suite("Failure lineage")
struct FuzzFailureLineageTests {
    @Test("A mutation-phase failure writes one row pairing the child with its corpus parent")
    func mutationFailureWritesParentAndChild() throws {
        let directory = NSTemporaryDirectory() + "failure-lineage-test-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: directory)
        }
        let runner = makeRunner(property: { values in
            values.contains { $0 > 90000 } ? .fail(.returnedFalse) : .pass
        })
        runner.failureLineage = try #require(FuzzFailureLineage(directory: directory, seed: 1337))
        let result = runner.run()
        #expect(result.clusters.isEmpty == false)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        let contents = try String(contentsOfFile: directory + "/" + #require(files.first), encoding: .utf8)
        let rows = try contents.split(separator: "\n").map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        #expect(rows.isEmpty == false)
        let mutationRows = rows.filter { ($0["origin"] as? String) == "mutationChild" }
        #expect(mutationRows.isEmpty == false, "no failing mutation child was traced")
        for row in mutationRows {
            #expect(row["parentSequence"] is String)
            #expect(row["parentValue"] is String)
            #expect((row["childValue"] as? String)?.isEmpty == false)
            #expect(row["symptom"] as? String == "returnedFalse")
            #expect(["duplicate", "unreduced", "unreduced-divergent", "reduce", "reduce-escape"].contains(row["gate"] as? String ?? ""))
            #expect((row["arms"] as? [String])?.isEmpty == false)
            #expect(row["parentChanged"] is [Any])
        }
        #expect(rows.contains { ($0["gate"] as? String) == "reduce" && ($0["cluster"] is String) })
    }

    @Test("The diff isolates the changed span between parent and child")
    func diffIsolatesChangedSpan() {
        let parent: ChoiceSequence = [.zip(true), entry(1), entry(2), entry(3), .zip(false)]
        var child = parent
        child.insert(entry(9), at: 2)
        let diff = FuzzFailureLineage.diff(parent: parent, child: child)
        #expect(diff.parentRange == 2 ..< 2)
        #expect(diff.childRange == 2 ..< 3)
        let same = FuzzFailureLineage.diff(parent: parent, child: parent)
        #expect(same.parentRange.isEmpty)
        #expect(same.childRange.isEmpty)
    }
}

// MARK: - Helpers

private func entry(_ value: UInt64) -> ChoiceSequenceValue {
    .value(.init(choice: ChoiceValue(value, tag: .uint64), validRange: nil))
}

private func makeRunner(
    property: @escaping @Sendable ([UInt64]) -> FuzzVerdict
) -> FuzzRunner<[UInt64]> {
    let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100_000), within: 0 ... 10)
    let source = SyntheticCoverageSource<[UInt64]>(edgeCount: 128) { values in
        var edges: [(edge: Int, hitCount: UInt8)] = [(edge: values.count, hitCount: 1)]
        for (position, value) in values.prefix(8).enumerated() {
            edges.append((edge: 11 + position * 10 + Int(value % 10), hitCount: UInt8(clamping: values.count)))
        }
        return edges
    }
    return FuzzRunner(
        gen: generator,
        property: property,
        source: source,
        configuration: FuzzRunnerConfiguration(
            budgetNanoseconds: 10_000_000_000,
            seed: 1337,
            skipScreening: true,
            attemptLimit: 8000
        )
    )
}
