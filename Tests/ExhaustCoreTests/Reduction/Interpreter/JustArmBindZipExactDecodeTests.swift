import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Reducer: zip bound after a just arm")
struct JustArmBindZipExactDecodeTests {
    /// A bind inner that selects a `.just` arm leaves the cursor on the `.just` entry, ahead of the pick's group close, when the bound zip starts. The zip parser skipped the `.just` but not the close, failed to parse, and scoped the first child from the lagging cursor position, so the first child's value fell outside its scope and exact replay rejected the generator's own sequence.
    @Test("Exact replay accepts a zip bound after a bind inner that selected a just arm", arguments: [false, true])
    func exactReplayAfterJustArm(materializePicks: Bool) throws {
        let generated = try justArmFixture(materializePicks: true)
        let sequence = ChoiceSequence.flatten(generated.tree)

        let result = Materializer.materialize(
            justArmBoundZip,
            context: .init(
                prefix: sequence,
                mode: .exact,
                fallbackTree: generated.tree,
                materializePicks: materializePicks
            )
        )

        guard case let .success(value, _, _) = result else {
            Issue.record("Expected exact replay to succeed, got \(result)")
            return
        }
        #expect(value == generated.value)
    }

    /// Sampling records only selected branches, so the reducer rematerializes the unselected arms before it can pivot. Without exact replay that rematerialization fails, the graph keeps only selected branches, and no branch pivot can reach the zero arm of the bound's pick, so the pick stops at its value arm's floor of one.
    @Test("A pick inside a zip bound after a just arm pivots to its first arm")
    func pickInBoundPivotsToFirstArm() throws {
        let generated = try justArmFixture(materializePicks: false)

        let result = ReductionSession.reduce(
            generator: justArmBoundZip,
            tree: generated.tree,
            output: generated.value,
            configuration: ReductionSession.Configuration(maxStalls: 2),
            collectStats: true,
            property: { triple in triple.0 == 0 }
        )

        let reduced = try #require(result.outcome.counterexample)
        #expect(reduced.1 == (1, 0, 0))
    }
}

// MARK: - Fixtures

/// A pick whose first arm is a `.just`, the shape of a type generator whose simplest type is a constant.
private let justFirstPick: Generator<UInt64> = Gen.pick(choices: [
    (weight: 1, generator: Gen.just(UInt64(0))),
    (weight: 3, generator: Gen.choose(in: UInt64(1) ... 100)),
])

/// The same arms as ``justFirstPick`` declared at another site, so its fingerprint differs and self-similar substitution cannot copy the controller's arm into it in place of a branch pivot.
private let boundPick: Generator<UInt64> = Gen.pick(choices: [
    (weight: 1, generator: Gen.just(UInt64(0))),
    (weight: 3, generator: Gen.choose(in: UInt64(1) ... 100)),
])

/// A bind over ``justFirstPick`` whose bound zips a free value, ``boundPick``, and the controller, as `genApp` binds an argument type and zips the function and argument terms.
private let justArmBoundZip: Generator<(UInt64, UInt64, UInt64)> = justFirstPick._bound(
    forward: { controller in
        Gen.zip(Gen.choose(in: UInt64(0) ... 100), boundPick, Gen.just(controller))
    },
    backward: { triple in triple.2 }
)

// MARK: - Helpers

/// The first generated value whose controller took the `.just` arm and whose bound pick took the value arm with a nonzero free value, so the cursor lags at the bound zip and the reducer has both a value to lower and an arm to pivot. With `materializePicks` false the tree holds only selected branches, as a sampled counterexample's does.
private func justArmFixture(materializePicks: Bool) throws -> (value: (UInt64, UInt64, UInt64), tree: ChoiceTree) {
    var iterator = ValueAndChoiceTreeInterpreter(justArmBoundZip, materializePicks: materializePicks, seed: 42)
    for _ in 0 ..< 200 {
        guard let candidate = try iterator.next() else {
            break
        }
        if candidate.value.2 == 0, candidate.value.1 > 0, candidate.value.0 > 0 {
            return candidate
        }
    }
    Issue.record("No iteration below 200 drew a just-arm controller with a value-arm bound pick")
    throw FixtureError()
}

private struct FixtureError: Error {}
