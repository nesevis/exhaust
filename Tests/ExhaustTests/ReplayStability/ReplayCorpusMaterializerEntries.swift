import Exhaust
import ExhaustCore
import Foundation
import Testing

extension ReplayCorpusEntry {
    /// Pins screening streams and individually addressed rows for public zip and pick generators.
    static var materializerScreeningEntries: [ReplayCorpusEntry] {
        MaterializerReplayFixture.all.flatMap { fixture in
            [
                ReplayCorpusEntry(name: "screening.materializer.\(fixture.name)") { seed in
                    captureMaterializerScreening(fixture.generator, replay: .numeric(seed))
                },
                ReplayCorpusEntry(name: "screening.addressed.\(fixture.name)") { seed in
                    (0 ..< fixture.screeningRows).flatMap { row in
                        captureMaterializerScreening(
                            fixture.generator,
                            replay: .encoded(ReplaySeed.encodeScreeningRow(
                                seed: seed,
                                row: row,
                                tierLength: nil
                            ))
                        )
                    }
                },
            ]
        }
    }
}

extension ReplayCorpusTests {
    @Test("Materialized screening rows replay exactly and agree with value-only emission")
    func materializedScreeningRowsReplay() throws {
        for fixture in MaterializerReplayFixture.all {
            let plan = try #require(ScreeningRunner.plan(fixture.generator.gen, screeningBudget: 8))
            let erased = fixture.generator.gen.erase()
            for seed in ReplayCorpusEntry.seeds {
                var rows = ScreeningRunner.Rows(plan: plan, coveringSeed: seed, skipToRow: nil)
                while let (index, row) = rows.next() {
                    let materialized: (value: (Int, Bool), tree: ChoiceTree)? = ScreeningRunner.materializeRow(
                        erased,
                        row: row,
                        rowIndex: index,
                        profile: plan.profile,
                        needsTree: true
                    )
                    let (expected, tree) = try #require(materialized)
                    let valueOnly: (value: (Int, Bool), tree: ChoiceTree)? = ScreeningRunner.materializeRow(
                        erased,
                        row: row,
                        rowIndex: index,
                        profile: plan.profile,
                        needsTree: false
                    )
                    let (withoutTree, _) = try #require(valueOnly)
                    #expect(withoutTree.0 == expected.0)
                    #expect(withoutTree.1 == expected.1)
                    for shouldUseFallback in [false, true] {
                        let result = Materializer.materializeAny(
                            erased,
                            context: .init(
                                prefix: ChoiceSequence(tree),
                                mode: .exact,
                                fallbackTree: shouldUseFallback ? tree : nil
                            )
                        )
                        guard case let .success(value, _, _) = result else {
                            Issue.record("Screening row failed exact replay: \(fixture.name), seed \(seed), row \(index)")
                            continue
                        }
                        let actual = try #require(value as? (Int, Bool))
                        #expect(actual.0 == expected.0)
                        #expect(actual.1 == expected.1)
                    }
                }
            }
        }
    }

    @Test("Exact wrapper replay agrees across tree, value-only, and flat emission")
    func exactWrapperEmissionParity() throws {
        for fixture in MaterializerReplayFixture.all {
            for seed in ReplayCorpusEntry.seeds {
                var interpreter = ValueAndChoiceTreeInterpreter(
                    fixture.generator.gen,
                    materializePicks: true,
                    seed: seed,
                    sizeOverride: 100
                )
                for _ in 0 ..< ReplayCorpusEntry.sampleCount {
                    let (expected, tree) = try #require(try interpreter.next())
                    let sequence = ChoiceSequence(tree)
                    let erased = fixture.generator.gen.erase()
                    for shouldSkipTree in [false, true] {
                        let result = Materializer.materializeAny(
                            erased,
                            context: .init(
                                prefix: sequence,
                                mode: .exact,
                                fallbackTree: tree,
                                skipTree: shouldSkipTree
                            )
                        )
                        guard case let .success(value, _, _) = result else {
                            Issue.record("Exact wrapper replay failed: \(fixture.name), seed \(seed), skipTree \(shouldSkipTree)")
                            continue
                        }
                        let actual = try #require(value as? (Int, Bool))
                        #expect(actual.0 == expected.0)
                        #expect(actual.1 == expected.1)
                    }
                    let flat = Materializer.materializeAnyFlat(
                        erased,
                        context: .init(
                            prefix: sequence,
                            mode: .exact,
                            fallbackTree: tree
                        )
                    )
                    guard case let .success(value, emitted, _) = flat else {
                        Issue.record("Exact flat wrapper replay failed: \(fixture.name), seed \(seed)")
                        continue
                    }
                    let actual = try #require(value as? (Int, Bool))
                    #expect(actual.0 == expected.0)
                    #expect(actual.1 == expected.1)
                    #expect(renderMaterializerSequence(emitted) == renderMaterializerSequence(sequence))
                }
            }
        }
    }

    @Test(
        "Export replay observations without replacing corpus expectations",
        .enabled(if: ProcessInfo.processInfo.environment["EXHAUST_MATERIALIZER_ISOLATION"] != nil)
    )
    func materializerIsolationCapture() async throws {
        for entry in ReplayCorpusEntry.all {
            for seed in ReplayCorpusEntry.seeds {
                let line = await ReplayCorpus.Line(entry: entry.name, seed: seed, values: entry.capture(seed))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(line)
                let serialized = try #require(String(bytes: data, encoding: .utf8))
                print("ISOLATION_CORPUS " + serialized)
            }
        }
        for fixture in MaterializerReplayFixture.all {
            for seed in ReplayCorpusEntry.seeds {
                var interpreter = ValueAndChoiceTreeInterpreter(
                    fixture.generator.gen,
                    materializePicks: true,
                    seed: seed,
                    sizeOverride: 100
                )
                for index in 0 ..< ReplayCorpusEntry.sampleCount {
                    let (value, tree) = try #require(try interpreter.next())
                    let sequence = ChoiceSequence(tree)
                    for mode in ["exact", "guided-prefix", "guided-fallback"] {
                        let result = Materializer.materializeAny(
                            fixture.generator.gen.erase(),
                            context: .init(
                                prefix: mode == "guided-fallback" ? ChoiceSequence() : sequence,
                                mode: mode == "exact" ? .exact : .guided(seed: seed, fallbackTree: nil),
                                fallbackTree: tree,
                                materializePicks: true,
                                shouldUseMaximumDepthForScreening: false
                            )
                        )
                        let observation: [String: Any] = [
                            "fixture": fixture.name,
                            "seed": seed,
                            "index": index,
                            "mode": mode,
                            "original": renderMaterializerValue(value),
                            "inputSequence": renderMaterializerSequence(sequence),
                            "result": renderMaterializerResult(result),
                        ]
                        let data = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
                        let serialized = try #require(String(bytes: data, encoding: .utf8))
                        print("ISOLATION_REPLAY " + serialized)
                    }
                }
            }
        }
    }
}

// MARK: - Fixtures and capture helpers

/// Holds identical public generator inputs across runner capture and direct materialization so replay comparisons do not vary fixture construction.
struct MaterializerReplayFixture: Sendable {
    let name: String
    let generator: ReflectiveGenerator<(Int, Bool)>
    let screeningRows: Int

    static var all: [MaterializerReplayFixture] {
        let first = #gen(.int(in: 0 ... 9), .bool())
        let second = #gen(.int(in: 10 ... 19), .bool())
        let pick = ReflectiveGenerator<(Int, Bool)>.oneOf(first, second)
        return [
            MaterializerReplayFixture(name: "zip", generator: first, screeningRows: 8),
            MaterializerReplayFixture(name: "pick", generator: pick, screeningRows: 2),
        ]
    }
}

/// Includes accounting alongside actual property inputs so an empty or rejected screening stream cannot silently look like successful row replay.
private func captureMaterializerScreening(
    _ generator: ReflectiveGenerator<(Int, Bool)>,
    replay: ReplaySeed
) -> [String] {
    let recorder = MaterializerValueRecorder()
    var report: ExhaustReport?
    #exhaust(
        generator,
        .replay(replay),
        .budget(.custom(screening: ReplayCorpusEntry.sampleCount, sampling: 0)),
        .onReport { report = $0 },
        .suppress(.all)
    ) { value in
        recorder.record(value)
    }
    var values = recorder.values
    values.append("rows=\(report?.screeningRows ?? -1),accepted=\(report?.screeningInvocations ?? -1),rejected=\(report?.screeningRejectedRows ?? -1)")
    return values
}

/// The serialized corpus suite never enables parallel property execution; this recorder is confined to one synchronous capture despite the macro's Sendable closure signature.
private final class MaterializerValueRecorder: @unchecked Sendable {
    private(set) var values: [String] = []

    func record(_ value: (Int, Bool)) -> Bool {
        values.append(renderMaterializerValue(value))
        return true
    }
}

private func renderMaterializerValue(_ value: (Int, Bool)) -> String {
    "\(value.0),\(value.1)"
}

/// Records flattened choices as well as values; identical outputs alone do not establish that later replay or reduction sees the same trace.
private func renderMaterializerResult(_ result: Materializer.Result<Any>) -> [String: Any] {
    switch result {
        case let .success(value, tree, _):
            guard let typed = value as? (Int, Bool) else {
                return ["status": "wrong-type"]
            }
            return [
                "status": "success",
                "value": renderMaterializerValue(typed),
                "sequence": renderMaterializerSequence(ChoiceSequence(tree)),
            ]
        case .rejected:
            return ["status": "rejected"]
        case .failed:
            return ["status": "failed"]
    }
}

/// Uses the flattened entry representation to retain structural markers and metadata rather than relying on depth-insensitive tree equivalence.
private func renderMaterializerSequence(_ sequence: ChoiceSequence) -> [String] {
    (0 ..< sequence.count).map { String(reflecting: sequence[$0]) }
}
