//
//  AdaptiveSmoothingTests.swift
//  ExhaustTests
//
//  Tests for adaptive Laplace smoothing of tuned generators.
//

import ExhaustCore
import Testing

@Suite("Adaptive Smoothing")
struct AdaptiveSmoothingTests {
    @Test("Smoothing preserves zip opacity in the rebuilt operation")
    func smoothingPreservesZipOpacity() {
        let gen = Gen.zip(
            Gen.choose(in: 1 ... 100),
            Gen.choose(in: 1 ... 100),
            isOpaque: true
        )

        let smoothed = AdaptiveSmoothing.smooth(gen)

        guard case let .impure(.transform(_, inner), _) = smoothed,
              case let .impure(.zip(_, isOpaque), _) = inner
        else {
            Issue.record("Smoothed generator no longer has the transform-over-zip shape")
            return
        }
        #expect(isOpaque, "Smoothing must preserve the zip's isOpaque flag")
    }

    @Test("Smoothed opaque zip still produces an opaque tree group")
    func smoothedOpaqueZipProducesOpaqueTreeGroup() throws {
        let gen = Gen.zip(
            Gen.choose(in: 1 ... 100),
            Gen.choose(in: 1 ... 100),
            isOpaque: true
        )

        let smoothed = AdaptiveSmoothing.smooth(gen)
        var interpreter = ValueAndChoiceTreeInterpreter(smoothed, seed: 42, maxRuns: 1)
        let (_, tree) = try #require(try interpreter.next())

        #expect(
            containsOpaqueGroup(tree),
            "The smoothed generator's tree lost the opaque group that shields screening analysis"
        )
    }
}

// MARK: - Helpers

private func containsOpaqueGroup(_ tree: ChoiceTree) -> Bool {
    switch tree {
        case let .group(children, isOpaque):
            if isOpaque {
                return true
            }
            return children.contains(where: containsOpaqueGroup)
        case let .sequence(elements, _):
            return elements.contains(where: containsOpaqueGroup)
        case let .branch(branchData):
            return containsOpaqueGroup(branchData.choice)
        case let .resize(_, choices):
            return choices.contains(where: containsOpaqueGroup)
        case let .bind(_, inner, bound):
            return containsOpaqueGroup(inner) || containsOpaqueGroup(bound)
        case .choice, .just, .getSize:
            return false
    }
}
