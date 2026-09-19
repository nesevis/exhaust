import Exhaust
import ExhaustCore
import Foundation
import Testing

extension ReplayCorpusEntry {
    /// Exercises both materializer emission modes through public generator factories and the public runner, including the default-array length path.
    static var materializerCoverageEntries: [ReplayCorpusEntry] {
        let wrappers = MaterializerReplayFixture.all.flatMap { fixture in
            screeningCoverageEntries("wrapper.\(fixture.name)", generator: fixture.generator) {
                "\($0.0),\($0.1)"
            }
        }
        return wrappers
            + screeningCoverageEntries(
                "default-array",
                generator: ReflectiveGenerator<[Int]>.array(.int(in: 0 ... 3))
            ) { String(describing: $0) }
            + screeningCoverageEntries(
                "resized-default-array",
                generator: ReflectiveGenerator<[Int]>.array(.int(in: 0 ... 3)).resize(20)
            ) { String(describing: $0) }
            + screeningCoverageEntries(
                "default-array-of-products",
                generator: ReflectiveGenerator<[(Int, Bool)]>.array(#gen(.int(in: 0 ... 3), .bool()))
            ) { values in
                values.map { "\($0.0):\($0.1)" }.joined(separator: ",")
            }
            + screeningCoverageEntries(
                "scaled-integer",
                generator: ReflectiveGenerator<Int>.int(in: 0 ... 100, scaling: .linear).resize(40)
            ) { String($0) }
            + screeningCoverageEntries(
                "array",
                generator: .array(.int(in: 0 ... 3), length: 0 ... 4, scaling: .constant)
            ) { String(describing: $0) }
            + screeningCoverageEntries(
                "filtered",
                generator: ReflectiveGenerator<Int>.int(in: 0 ... 7).filter(.rejectionSampling) { $0 % 2 == 0 },
                canReplayEveryRow: false
            ) { String($0) }
            + screeningCoverageEntries(
                "derived-product",
                generator: CorpusMaterializerRecord.gen(maximumDepth: 5, overriding: .int(in: 0 ... 9))
            ) { "\($0.first),\($0.flag)" }
            + screeningCoverageEntries(
                "budgeted-product",
                generator: CorpusMaterializerRecord.gen(
                    maximumDepth: 5,
                    maximumNodes: 32,
                    overriding: .int(in: 0 ... 9)
                )
            ) { "\($0.first),\($0.flag)" }
            + screeningCoverageEntries(
                "nested-product",
                generator: CorpusMaterializerNested.gen(
                    maximumDepth: 5,
                    maximumNodes: 32,
                    overriding: .int(in: 0 ... 9)
                )
            ) { "\($0.inner.first),\($0.inner.flag),\($0.outer)" }
            + screeningCoverageEntries(
                "budgeted-array",
                generator: CorpusMaterializerArray.gen(
                    maximumDepth: 4,
                    maximumNodes: 16,
                    overriding: .int(in: 0 ... 3)
                )
            ) { "\($0.values),\($0.label)" }
            + screeningCoverageEntries(
                "recursive",
                generator: CorpusMaterializerTree.gen(
                    maximumDepth: 3,
                    maximumNodes: 16,
                    overriding: .int(in: 0 ... 3)
                )
            ) { $0.rendering }
    }
}

extension ReplayCorpusTests {
    @Test("Tree-building screening matches value-only screening and addressed rows match their stream")
    func screeningEmissionAndAddressParity() async throws {
        let entries = ReplayCorpusEntry.materializerCoverageEntries
        let treeEntries = entries.filter { $0.name.contains(".tree.") }
        let addressedEntries = entries.filter { $0.name.hasSuffix(".addressed") }
        #expect(treeEntries.isEmpty == false)
        #expect(addressedEntries.isEmpty == false)
        for entry in treeEntries {
            let valueName = entry.name.replacingOccurrences(of: ".tree.", with: ".value.")
            let valueEntry = try #require(entries.first { $0.name == valueName })
            for seed in ReplayCorpusEntry.seeds {
                let withTree = await entry.capture(seed)
                let withoutTree = await valueEntry.capture(seed)
                #expect(withTree == withoutTree)
            }
        }
        for entry in addressedEntries {
            let streamName = entry.name.replacingOccurrences(of: ".addressed", with: ".stream")
            let streamEntry = try #require(entries.first { $0.name == streamName })
            for seed in ReplayCorpusEntry.seeds {
                let addressed = await entry.capture(seed)
                let stream = await streamEntry.capture(seed)
                #expect(
                    addressed.filter { $0.hasPrefix("rows=") == false }
                        == stream.filter { $0.hasPrefix("rows=") == false }
                )
            }
        }
    }
}

// MARK: - Capture helpers

/// Makes full-stream and addressed-row captures in both emission modes. Address counts come from the actual public run rather than assuming every model spends its whole budget. Filtered streams pin rejection accounting without asking the public replay API to reproduce rows that never reached the property.
private func screeningCoverageEntries<Output>(
    _ name: String,
    generator: ReflectiveGenerator<Output>,
    canReplayEveryRow: Bool = true,
    render: @escaping @Sendable (Output) -> String
) -> [ReplayCorpusEntry] {
    let addressingModes = canReplayEveryRow ? [false, true] : [false]
    return [false, true].flatMap { shouldBuildTrees in
        addressingModes.map { isAddressed in
            let mode = shouldBuildTrees ? "tree" : "value"
            let addressing = isAddressed ? "addressed" : "stream"
            return ReplayCorpusEntry(name: "screening.coverage.\(name).\(mode).\(addressing)") { seed in
                let stream = captureScreeningCoverage(
                    generator,
                    replay: .numeric(seed),
                    shouldBuildTrees: shouldBuildTrees,
                    render: render
                )
                guard isAddressed else {
                    return stream.values
                }
                return (0 ..< stream.attempts).flatMap { row in
                    captureScreeningCoverage(
                        generator,
                        replay: .encoded(ReplaySeed.encodeScreeningRow(seed: seed, row: row, tierLength: nil)),
                        shouldBuildTrees: shouldBuildTrees,
                        render: render
                    ).values
                }
            }
        }
    }
}

/// Collecting OpenPBTStats installs screening's onExample callback, forcing tree-building materialization. Without it, passing rows take the value-only materializer path. Sampling is disabled in both cases.
private func captureScreeningCoverage<Output>(
    _ generator: ReflectiveGenerator<Output>,
    replay: ReplaySeed,
    shouldBuildTrees: Bool,
    render: @escaping @Sendable (Output) -> String
) -> (values: [String], attempts: Int) {
    let recorder = ScreeningCoverageRecorder()
    var capturedReport: ExhaustReport?
    let emissionSetting: PropertySettings = shouldBuildTrees ? .collectOpenPBTStats : .suppress(.attachments)
    #exhaust(
        generator,
        .replay(replay),
        .budget(.custom(screening: ReplayCorpusEntry.sampleCount, sampling: 0)),
        emissionSetting,
        .onReport { capturedReport = $0 },
        .suppress(.all)
    ) { value in
        recorder.record(render(value))
    }
    guard let report = capturedReport else {
        Issue.record("Screening corpus capture did not produce an ExhaustReport")
        return (["missing-report"], 0)
    }
    #expect(report.randomSamplingInvocations == 0)
    #expect(report.screeningRows > 0)
    #expect(report.screeningInvocations > 0)
    #expect(recorder.values.count == report.screeningInvocations)
    let expectedStatistics = shouldBuildTrees ? report.screeningInvocations : 0
    #expect(report.openPBTStatsLines.count == expectedStatistics)
    var values = recorder.values
    values.append("rows=\(report.screeningRows),accepted=\(report.screeningInvocations),rejected=\(report.screeningRejectedRows)")
    return (values, report.screeningRows)
}

/// Confined to one synchronous, nonparallel public run in the serialized corpus suite; unchecked Sendable accommodates the macro's property closure without introducing shared mutable state between captures.
private final class ScreeningCoverageRecorder: @unchecked Sendable {
    private(set) var values: [String] = []

    func record(_ value: String) -> Bool {
        values.append(value)
        return true
    }
}

// MARK: - Derived fixtures

@Exhaustable
private struct CorpusMaterializerRecord {
    let first: Int
    let flag: Bool
}

@Exhaustable
private struct CorpusMaterializerNested {
    let inner: CorpusMaterializerRecord
    let outer: Int
}

@Exhaustable
private struct CorpusMaterializerArray {
    let values: [Int]
    let label: Int
}

@Exhaustable
private indirect enum CorpusMaterializerTree {
    case leaf(Int)
    case branch(CorpusMaterializerTree, CorpusMaterializerTree)

    var rendering: String {
        switch self {
            case let .leaf(value):
                "leaf(\(value))"
            case let .branch(first, second):
                "branch(\(first.rendering),\(second.rendering))"
        }
    }
}
