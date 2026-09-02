//
//  MetamorphReflectionTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

@Suite("Metamorph reflection")
struct MetamorphReflectionTests {
    @Test("An array with one component per transform plus the original reflects")
    func matchingLengthReflects() throws {
        let gen = metamorphOverZero()
        let tree = try #require(try Interpreters.reflect(gen, with: [0, 0]))
        let replayed = try #require(try Interpreters.replay(gen, using: tree))
        #expect(replayed as? [Int] == [0, 0])
    }

    @Test("An array of another length is not this node's output")
    func otherLengthIsRejected() throws {
        let gen = metamorphOverZero()
        #expect(throws: ReflectionError.self) {
            _ = try Interpreters.reflect(gen, with: [0])
        }
        #expect(throws: ReflectionError.self) {
            _ = try Interpreters.reflect(gen, with: [0, 0, 0])
        }
    }

    @Test("A pick does not select a metamorph arm for a sibling arm's array")
    func pickFallsThroughToSiblingArm() throws {
        // Both arms work on erased elements: the tuple isomorph hands the metamorphic node an `[Any]`, and a typed sibling would refuse that shape before the pick ever compared values.
        let gen: AnyGenerator = Gen.pick(choices: [
            (1, metamorphOverZero()),
            (1, Gen.arrayOf(Gen.just(0).erase(), exactly: 1).erase()),
        ])
        let single = try #require(try Interpreters.reflect(gen, with: [0] as [Any]))
        let singleBranch = try #require(firstBranch(in: single))
        #expect(singleBranch.id == 1)
        #expect(try Interpreters.replay(gen, using: single) as? [Int] == [0])

        let pair = try #require(try Interpreters.reflect(gen, with: [0, 0] as [Any]))
        let pairBranch = try #require(firstBranch(in: pair))
        #expect(pairBranch.id == 0)
        #expect(try Interpreters.replay(gen, using: pair) as? [Int] == [0, 0])
    }

    @Test("A stale transformed member still reflects at the top level")
    func staleMemberReflectsAtTopLevel() throws {
        let gen = metamorphOverZero()
        let tree = try #require(try Interpreters.reflect(gen, with: [0, 99] as [Any]))
        #expect(try Interpreters.replay(gen, using: tree) as? [Int] == [0, 0])
    }

    @Test("A pick does not select a metamorph arm for a same-length array whose members it would not produce")
    func pickRejectsMismatchedMembers() throws {
        let gen: AnyGenerator = Gen.pick(choices: [
            (1, metamorphOverZero()),
            (1, Gen.arrayOf(Gen.choose(in: -1 ... 0).erase(), exactly: 2).erase()),
        ])
        let tree = try #require(try Interpreters.reflect(gen, with: [0, -1] as [Any]))
        let branch = try #require(firstBranch(in: tree))
        #expect(branch.id == 1)
        #expect(try Interpreters.replay(gen, using: tree) as? [Int] == [0, -1])
    }

    @Test("Transforms run during reflection only inside a pick probe")
    func transformsRunOnlyInsidePickProbes() throws {
        let counter = Counter()
        let counted: AnyGenerator = .impure(
            operation: .transform(
                kind: .metamorphic(transforms: [{ counter.increment(); return $0 }], inputType: Int.self),
                inner: Gen.just(0).erase()
            ),
            continuation: { .pure($0) }
        )
        _ = try Interpreters.reflect(counted, with: [0, 0] as [Any])
        #expect(counter.invocations == 0)

        let pick: AnyGenerator = Gen.pick(choices: [(1, counted), (1, Gen.just([0, 0] as [Any]).erase())])
        _ = try Interpreters.reflect(pick, with: [0, 0] as [Any])
        #expect(counter.invocations == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private(set) var invocations = 0

    func increment() {
        invocations += 1
    }
}

// MARK: - Helpers

/// A one-transform metamorph over a constant, producing `[0, 0]`.
private func metamorphOverZero() -> AnyGenerator {
    .impure(
        operation: .transform(
            kind: .metamorphic(transforms: [{ $0 }], inputType: Int.self),
            inner: Gen.just(0).erase()
        ),
        continuation: { .pure($0) }
    )
}

private func firstBranch(in tree: ChoiceTree) -> ChoiceSequenceValue.Branch? {
    ChoiceSequence.flatten(tree).lazy.compactMap { entry -> ChoiceSequenceValue.Branch? in
        guard case let .branch(branch) = entry else { return nil }
        return branch
    }.first
}
