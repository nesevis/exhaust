import Testing
@testable import ExhaustCore

@Suite("Scoped staged joint encoder")
struct ScopedStagedJointEncoderTests {
    @Test("A deadline that expires between stages starts no further stage", arguments: [1, 2])
    func deadlineBetweenStages(completedStages: Int) throws {
        // Only an exact linear quadruple fails, so the pair and three-way stages exhaust and the search escalates to four leaves.
        let fixture = try StagedJointFixture(values: [2, 4, 6, 10]) { values in
            values[1] != 2 * values[0] || values[2] != 3 * values[0] || values[3] != 5 * values[0]
        }
        let complete = fixture.run()
        #expect(complete.report.searchCounts.map(\.stagedJointArity) == [2, 3, 4])
        let completed = complete.report.searchCounts.prefix(completedStages)
        let emissions = completed.reduce(0) { $0 + $1.counts.emitted }
        let checksAtLastProbe = try #require(complete.checksAtTermination[emissions])

        // The last completed stage's exhaustion check passes; the next check precedes the following stage.
        let interrupted = fixture.run(deadlineAfterChecks: checksAtLastProbe + 1)

        #expect(interrupted.report.searchCounts == Array(completed))
        #expect(interrupted.report.counts.emitted == emissions)
    }
}

// MARK: - Fixture

/// Values reflected through a zip of broad integer generators, with every leaf marked converged so the checkpoint is stalled.
private struct StagedJointFixture {
    struct Run {
        let report: ScopedPassReport
        /// Deadline checks made by the time each probe ID terminated.
        let checksAtTermination: [Int: Int]
    }

    let values: [Int]
    let generator: AnyGenerator
    let tree: ChoiceTree
    let graph: ChoiceGraph
    let sequence: ChoiceSequence
    let scope: ScopedStagedJointEncoder.Scope
    let property: (Any) -> Bool
    static let tuning = ScopedReductionTuning()

    init(values: [Int], passes: @escaping ([Int]) -> Bool) throws {
        let typed = Gen.eachOf(Array(repeating: Gen.choose(in: 1 ... 1_000_000), count: values.count))
        let reflected = try #require(try Interpreters.reflect(typed, with: values))
        var built = ChoiceGraph.build(from: reflected)
        Self.markConverged(&built)
        self.values = values
        generator = typed.erase()
        tree = reflected
        graph = built
        sequence = ChoiceSequence(reflected)
        property = { output in passes(output as! [Int]) }
        scope = ScopedStagedJointEncoder.Scope(
            pairs: ScopedStagedJointQuery.pairs(graph: built, isFruitlessBind: { _ in false }, tuning: Self.tuning),
            candidatePool: ScopedStagedJointQuery.candidatePool(graph: built, isFruitlessBind: { _ in false }, tuning: Self.tuning)
        )
    }

    /// - Parameter deadlineAfterChecks: Expires the deadline once this many checks have passed; nil never expires.
    func run(deadlineAfterChecks: Int? = nil) -> Run {
        let checks = CheckCounter()
        let input = ScopedEncoderInput(baseSequence: sequence, tree: tree, graph: graph, warmStartRecords: [:], tuning: Self.tuning)
        let result = ScopedReductionInterpreter.run(
            ScopedStagedJointEncoder.reducer(scope, input: input),
            context: ScopedReductionInterpreter.Context(
                incumbent: ScopedCounterexample(
                    sequence: sequence,
                    tree: tree,
                    output: values
                ),
                graph: graph,
                rejectCache: [],
                decoder: ScopedDecoder(
                    generator: generator,
                    property: property,
                    probeWrapper: nil,
                    hasBind: false
                ),
                encoder: ScopedStagedJointEncoder.self,
                // Every check reads the clock once, so the clock counts checks. Without a limit the budget is never reached, but each check still reads it.
                deadline: ScopedDeadline(start: 0, budget: deadlineAfterChecks.map { UInt64($0) + 1 } ?? .max) {
                    checks.count += 1
                    return UInt64(checks.count)
                },
                observer: { observation in
                    if case let .terminated(probeID, _, _) = observation {
                        checks.atTermination[probeID] = checks.count
                    }
                }
            )
        )
        return Run(report: result.report, checksAtTermination: checks.atTermination)
    }

    /// Settles every leaf at its current value, so each nontrivial leaf is a stalled source.
    private static func markConverged(_ graph: inout ChoiceGraph) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                continue
            }
            graph.convergenceStore[nodeID] = ConvergedOrigin(
                bound: metadata.value.bitPattern64,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
        }
    }
}

/// Counts deadline checks across an interpreter run.
private final class CheckCounter {
    var count = 0
    var atTermination: [Int: Int] = [:]
}
