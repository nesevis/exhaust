import ExhaustCore
import Foundation
import Testing
import XCTest
@testable import Exhaust

@Suite("Pointless runs and skip accounting")
struct PointlessRunAndSkipTests {
    @Test("Zero-budget run reports a pointless-run error")
    func zeroBudgetReportsError() {
        var invocations = -1
        withKnownIssue {
            #exhaust(
                #gen(.int(in: 0 ... 100)),
                .budget(.custom(coverage: 0, sampling: 0)),
                .onReport { report in
                    invocations = report.propertyInvocations
                }
            ) { _ in
                false
            }
        }
        #expect(invocations == 0)
    }

    @Test("Run where every invocation throws PropertySkip reports a pointless-run error")
    func allSkippedReportsError() {
        var skipped = -1
        var invocations = -1
        withKnownIssue {
            #exhaust(
                #gen(.int(in: 0 ... 100)),
                .budget(.quick),
                .onReport { report in
                    skipped = report.skippedInvocations
                    invocations = report.propertyInvocations
                }
            ) { (value: Int) -> Bool in
                if value >= 0 {
                    throw PropertySkip()
                }
                return false
            }
        }
        #expect(invocations == 200)
        #expect(skipped == invocations)
    }

    @Test("XCTSkip thrown from the property counts as a skip")
    func xctSkipCountsAsSkip() {
        var skipped = -1
        withKnownIssue {
            #exhaust(
                #gen(.int(in: 0 ... 100)),
                .budget(.quick),
                .onReport { report in
                    skipped = report.skippedInvocations
                }
            ) { (value: Int) -> Bool in
                if value >= 0 {
                    throw XCTSkip("environmental")
                }
                return false
            }
        }
        #expect(skipped == 200)
    }

    @Test("Partially skipped run passes and tallies the skips")
    func partialSkipsPassAndAreCounted() {
        var skipped = -1
        var invocations = -1
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.quick),
            .onReport { report in
                skipped = report.skippedInvocations
                invocations = report.propertyInvocations
            }
        ) { (value: Int) -> Bool in
            if value < 30 {
                throw PropertySkip()
            }
            return true
        }
        #expect(result == nil)
        #expect(skipped > 0)
        #expect(skipped < invocations)
    }

    @Test("Contract run with zero budget reports a pointless-run error")
    func contractZeroBudgetReportsError() async {
        await withKnownIssue {
            _ = await #execute(
                PointlessRunStackSpec.self,
                .budget(.custom(coverage: 0, sampling: 0))
            )
        }
    }
}

@Suite("Unique exhaustion truncation")
struct UniqueExhaustionTruncationTests {
    @Test("Exhausted unique site surfaces the truncation in the report")
    func exhaustedUniqueSurfacesTruncation() {
        var truncated = false
        var invocations = -1
        withKnownIssue {
            #exhaust(
                #gen(.bool()).unique(),
                .budget(.custom(coverage: 0, sampling: 200)),
                .onReport { report in
                    truncated = report.runTruncatedByUniqueExhaustion
                    invocations = report.propertyInvocations
                }
            ) { _ in
                true
            }
        }
        #expect(truncated)
        #expect(invocations < 200)
    }

    @Test("Small domain with coverage enabled passes exhaustively, not by truncation")
    func smallDomainCoverageIsExhaustive() {
        var truncated = true
        var coverage = -1
        #exhaust(
            #gen(.bool()).unique(),
            .budget(.standard),
            .onReport { report in
                truncated = report.runTruncatedByUniqueExhaustion
                coverage = report.coverageInvocations
            }
        ) { _ in
            true
        }
        #expect(truncated == false)
        #expect(coverage == 2)
    }

    @Test("Unique over a large domain does not truncate")
    func largeDomainDoesNotTruncate() {
        var truncated = true
        #exhaust(
            #gen(.int(in: 0 ... 1_000_000)).unique(),
            .budget(.quick),
            .onReport { report in
                truncated = report.runTruncatedByUniqueExhaustion
            }
        ) { _ in
            true
        }
        #expect(truncated == false)
    }
}

@Suite("Explore direction coverage failures")
struct ExploreCoverageFailureTests {
    @Test("Unreachable direction fails the test")
    func uncoveredDirectionFails() {
        var outcome: DirectionOutcome?
        withKnownIssue {
            let report = #explore(
                #gen(.int(in: 0 ... 100)),
                directions: [
                    ("impossible", { $0 > 1000 }),
                ],
                .budget(.quick)
            ) { _ in
                true
            }
            outcome = report.directionCoverage.first?.outcome
        }
        #expect(outcome == .uncovered)
    }

    @Test("Unreachable direction with suppression stays silent and keeps the report")
    func uncoveredDirectionSuppressed() {
        let report = #explore(
            #gen(.int(in: 0 ... 100)),
            directions: [
                ("impossible", { $0 > 1000 }),
            ],
            .budget(.quick),
            .suppress(.issueReporting)
        ) { _ in
            true
        }
        #expect(report.directionCoverage.first?.outcome == .uncovered)
        #expect(report.termination == .budgetExhausted)
    }

    @Test("Reachable directions still pass")
    func coveredDirectionsPass() {
        let report = #explore(
            #gen(.int(in: 0 ... 100)),
            directions: [
                ("low", { $0 < 50 }),
                ("high", { $0 >= 50 }),
            ],
            .budget(.quick)
        ) { _ in
            true
        }
        let allCovered = report.directionCoverage.allSatisfy(\.isCovered)
        #expect(allCovered)
    }
}

@Suite("Misuse validation")
struct MisuseValidationTests {
    @Test("Example with a negative count throws instead of trapping")
    func exampleNegativeCountThrows() {
        withKnownIssue {
            #expect(throws: GeneratorError.self) {
                _ = try #example(#gen(.int(in: 0 ... 9)), count: -1)
            }
        }
    }

    @Test("Non-positive idle timeout resolves to unbounded")
    func nonPositiveIdleTimeoutIsUnbounded() {
        let zero = ResolvedConcurrentConfig.parse([.idleTimeoutMs(0)])
        #expect(zero.config.resolvedIdleTimeoutMilliseconds == nil)

        let negative = ResolvedConcurrentConfig.parse([.idleTimeoutMs(-5)])
        #expect(negative.config.resolvedIdleTimeoutMilliseconds == nil)

        let positive = ResolvedConcurrentConfig.parse([.idleTimeoutMs(500)])
        #expect(positive.config.resolvedIdleTimeoutMilliseconds == 500)
    }
}

@Suite("Weighted oneOf zero-weight entries")
struct WeightedOneOfZeroWeightTests {
    @Test("Zero-weight entries are never drawn")
    func zeroWeightEntriesAreNeverDrawn() {
        let result = #exhaust(
            #gen(.oneOf(weighted: (0, .just(1)), (1, .just(2)), (1, .just(3)))),
            .budget(.custom(coverage: 0, sampling: 100)),
            .suppress(.issueReporting)
        ) { value in
            value != 1
        }
        #expect(result == nil)
    }

    @Test("Single surviving entry is returned directly")
    func singleSurvivorIsReturnedDirectly() {
        let result = #exhaust(
            #gen(.oneOf(weighted: (0, .just(1)), (3, .just(2)))),
            .budget(.custom(coverage: 0, sampling: 50)),
            .suppress(.issueReporting)
        ) { value in
            value == 2
        }
        #expect(result == nil)
    }

    @Test("Zero-weight removal to one entry leaves no branch node in the choice tree")
    func singleSurvivorTreeHasNoBranchNode() throws {
        let tree = try generatedTree(of: .oneOf(weighted: (0, .just(1)), (3, .just(2))))
        #expect(containsBranchNode(tree) == false)
    }

    @Test("Multiple surviving entries keep the pick's branch node")
    func multipleSurvivorsTreeKeepsBranchNode() throws {
        let tree = try generatedTree(of: .oneOf(weighted: (0, .just(1)), (1, .just(2)), (3, .just(3))))
        #expect(containsBranchNode(tree))
    }

    @Test("A list that starts with one entry keeps its pick node")
    func singleEntryListKeepsBranchNode() throws {
        let tree = try generatedTree(of: .oneOf(weighted: [(1, .just(2))]))
        #expect(containsBranchNode(tree))
    }
}

// MARK: - Helpers

/// Generates one value from the generator and returns its choice tree.
private func generatedTree(of gen: ReflectiveGenerator<Int>) throws -> ChoiceTree {
    var interpreter = ValueAndChoiceTreeInterpreter<Int>(gen.gen, materializePicks: false, seed: 1, maxRuns: 1)
    let element = try #require(try interpreter.next())
    return element.1
}

/// Returns whether any node in the tree is a `.branch` (the flattened form of a pick).
private func containsBranchNode(_ tree: ChoiceTree) -> Bool {
    switch tree {
        case .choice, .just, .getSize:
            false
        case .branch:
            true
        case let .sequence(_, elements, _):
            elements.contains(where: containsBranchNode)
        case let .group(children, _):
            children.contains(where: containsBranchNode)
        case let .resize(_, children):
            children.contains(where: containsBranchNode)
        case let .bind(_, inner, bound):
            containsBranchNode(inner) || containsBranchNode(bound)
    }
}

// MARK: - Fixtures

/// Deliberately minimal: a single command is enough for a fixture whose tests only verify run-level reporting, never state transitions.
@Contract(.sequential)
final class PointlessRunStackSpec {
    var expected: [Int] = []
    @SystemUnderTest var stack: [Int] = []

    @Invariant
    func contentsMatch() -> Bool {
        stack == expected
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func push(value: Int) throws {
        expected.append(value)
        stack.append(value)
    }

    func failureDescription() -> String? {
        "\(stack)"
    }
}
