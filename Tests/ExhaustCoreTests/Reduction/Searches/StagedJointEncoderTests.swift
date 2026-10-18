import Testing
@testable import ExhaustCore

@Suite("Staged joint encoder")
struct StagedJointEncoderTests {
    @Test("Coordinated search reaches the primitive ratio after cheaper stages stall", arguments: [[2, 4], [2, 4, 6], [2, 4, 6, 10]])
    func coordinatedSearchFindsPrimitiveRatio(values: [Int]) throws {
        let primitive = values.map { $0 / 2 }
        let fixture = try StagedJointFixture(values: values) { candidate in
            candidate.indices.contains { candidate[$0] != primitive[$0] * candidate[0] }
        }

        let result = fixture.run()

        #expect(result.output == primitive)
        #expect(result.report.anyAccepted)
        #expect(result.report.searchCounts.map(\.stagedJointArity) == Array(2 ... values.count))
        #expect(result.report.searchCounts.dropLast().allSatisfy { $0.counts.accepted == 0 })
        #expect(result.report.searchCounts.last?.counts.accepted == 1)
    }

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
        let report: ReductionPassReport
        let output: [Int]
        /// Deadline checks made by the time each probe ID terminated.
        let checksAtTermination: [Int: Int]
    }

    let values: [Int]
    let generator: AnyGenerator
    let tree: ChoiceTree
    let graph: ChoiceGraph
    let sequence: ChoiceSequence
    let scope: StagedJointEncoder.Scope
    let property: (Any) -> Bool
    static let tuning = ReductionTuning()

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
        scope = StagedJointEncoder.Scope(
            pairs: StagedJointQuery.pairs(graph: built, isFruitlessBind: { _ in false }, tuning: Self.tuning),
            candidatePool: StagedJointQuery.candidatePool(graph: built, isFruitlessBind: { _ in false }, tuning: Self.tuning)
        )
    }

    /// - Parameter deadlineAfterChecks: Expires the deadline once this many checks have passed; nil never expires.
    func run(deadlineAfterChecks: Int? = nil) -> Run {
        let checks = CheckCounter()
        let input = EncoderInput(baseSequence: sequence, tree: tree, graph: graph, warmStartRecords: [:], tuning: Self.tuning)
        let result = Reducer.reduce(
            StagedJointEncoder.reduce(scope, input: input),
            context: Reducer.Context(
                incumbent: Counterexample(
                    sequence: sequence,
                    tree: tree,
                    output: values
                ),
                incumbentHash: ZobristHash.hash(of: sequence),
                graph: graph,
                rejectCache: [],
                decoder: ReductionDecoder(
                    generator: generator,
                    property: property,
                    probeWrapper: nil,
                    hasBind: false
                ),
                encoder: StagedJointEncoder.self,
                // Every check reads the clock once, so the clock counts checks. Without a limit the budget is never reached, but each check still reads it.
                deadline: ReductionDeadline(start: 0, budget: deadlineAfterChecks.map { UInt64($0) + 1 } ?? .max) {
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
        return Run(report: result.report, output: result.incumbent.output as! [Int], checksAtTermination: checks.atTermination)
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
