//
//  UniformCollapseTests.swift
//  Exhaust
//
//  Pins the Stage-4 collapse restriction in ChoiceGradientTuner. The uniform-collapse pass exists to undo Stage 0's chooseBits-into-pick subdivisions when tuning found no signal, but its structural guard also matched user-written oneOf-of-chooses: collapsing those broke structural compatibility with the untuned generator (exact replay of tuned flattenings rejected) and merged gapped branch ranges into values from neither branch. Found by the self-fuzzing harness (ExhaustDocs/coverage-guided-self-fuzzing.md).
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("CGS uniform collapse")
struct UniformCollapseTests {
    @Test("A tuned filter over a gapped oneOf never generates values from the gap")
    func gappedOneOfStaysInDomain() throws {
        let gen = filteredPick(
            first: 0 ... 5,
            second: 10 ... 15,
            sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
        )
        var iterator = ValueInterpreter(gen, seed: 7, maxRuns: 200)
        var generated = 0
        while let value = try iterator.next() {
            let intValue = try #require(value as? Int)
            #expect(
                (0 ... 5).contains(intValue) || (10 ... 15).contains(intValue),
                "Generated \(intValue), a value in neither oneOf branch"
            )
            generated += 1
        }
        #expect(generated == 200)
    }

    @Test("A tuned filter over a user pick keeps the pick's tree structure")
    func userPickKeepsStructure() throws {
        let gen = filteredPick(
            first: 0 ... 5,
            second: 10 ... 15,
            sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
        )
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 20)
        var checked = 0
        while let (value, tree) = try iterator.next() {
            let sequence = ChoiceSequence.flatten(tree)
            #expect(
                sequence.contains { entry in
                    if case .branch = entry {
                        return true
                    }
                    return false
                },
                "Tuned generation elided the user pick's branch entry"
            )
            switch Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) {
                case let .success(materialized, _, _):
                    #expect(anyEquals(materialized, value))
                case .rejected, .failed:
                    Issue.record("Exact replay rejected a tuned generation's own flattening")
                    return
            }
            checked += 1
        }
        #expect(checked == 20)
    }
}

// MARK: - Helpers

/// A user-written two-branch pick of chooses under a CGS-tuned filter — the shape the Stage-4 collapse used to swallow. Each test passes its own source location so the process-wide tuned-filter cache gives every call site a distinct slot.
private func filteredPick(
    first: ClosedRange<Int>,
    second: ClosedRange<Int>,
    sourceLocation: FilterSourceLocation
) -> AnyGenerator {
    let inner = Gen.pick(choices: [
        (1, Gen.choose(in: first).erase()),
        (1, Gen.choose(in: second).erase()),
    ])
    return Gen.filter(
        inner,
        type: .auto,
        predicate: { _ in true },
        sourceLocation: sourceLocation
    )
}
