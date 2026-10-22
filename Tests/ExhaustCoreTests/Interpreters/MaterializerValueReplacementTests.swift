import Testing
@testable import ExhaustCore

@Suite("Shared-prefix value replacements")
struct MaterializerValueReplacementTests {
    @Test("Scalar and bulk reads agree with a copied prefix", arguments: [0, 1, 2])
    func scalarAndBulkReads(index: Int) {
        let original = ChoiceSequence([1, 2, 3].map { value in
            .value(.init(choice: ChoiceValue(UInt64(value), tag: .uint64), validRange: 0 ... 10))
        })
        let replacement = ChoiceSequenceValueReplacement(
            index: index,
            value: .init(choice: ChoiceValue(UInt64(9), tag: .uint8), validRange: 0 ... 20)
        )
        var copied = original
        copied[index] = .value(replacement.value)
        var sharedCursor = Materializer.Cursor(from: original, valueReplacement: replacement)
        var copiedCursor = Materializer.Cursor(from: copied)
        let checkpoint = sharedCursor.checkpoint
        for _ in 0 ..< original.count {
            #expect(sharedCursor.peekScalarValue(expecting: .uint64) == copiedCursor.peekScalarValue(expecting: .uint64))
            #expect(sharedCursor.tryConsumeValue(expecting: .uint64) == copiedCursor.tryConsumeValue(expecting: .uint64))
        }
        sharedCursor.rewind(to: checkpoint)
        copiedCursor.rewind(to: checkpoint)
        #expect(sharedCursor.tryConsumeScalarValues(count: 3, expecting: .uint64) == copiedCursor.tryConsumeScalarValues(count: 3, expecting: .uint64))
        #expect(original[index].value?.choice.bitPattern64 == UInt64(index + 1))
    }

    @Test("Replacement tags, scope limits and suspension match an edited prefix")
    func cursorBoundaries() {
        let original: ChoiceSequence = [.value(.init(choice: ChoiceValue(UInt64(1), tag: .uint64), validRange: nil))]
        let replacement = ChoiceSequenceValueReplacement(index: 0, value: .init(choice: ChoiceValue(UInt64(2), tag: .depthControl), validRange: nil))
        var cursor = Materializer.Cursor(from: original, valueReplacement: replacement)
        #expect(cursor.peekScalarValue(expecting: .uint64) == nil)
        #expect(cursor.tryConsumeScalarValues(count: 1, expecting: .uint64) == nil)
        #expect(cursor.position == 0)
        cursor.pushScope(limit: 0)
        #expect(cursor.tryConsumeScalarValues(count: 1, expecting: .depthControl) == nil)
        cursor.popScope()
        cursor.suspended = true
        #expect(cursor.tryConsumeValue(expecting: .depthControl) == nil)
        cursor.suspended = false
        #expect(cursor.tryConsumeValue(expecting: .depthControl) == replacement.value)
    }

    @Test("Guided lifts preserve nested structure and ceilings for every edited value")
    func liftedTreeParity() throws {
        let generator = Gen.choose(in: 1 ... 4).bind { length in
            Gen.arrayOf(Gen.choose(in: 0 ... 10), exactly: UInt64(length))
        }
        var interpreter = ValueAndChoiceTreeInterpreter(generator, materializePicks: true, seed: 1337, maxRuns: 10)
        var count = 0
        while let (_, tree) = try interpreter.next() {
            let original = ChoiceSequence(tree)
            for index in original.indices {
                guard let value = original[index].value else {
                    continue
                }
                let replacement = ChoiceSequenceValueReplacement(index: index, value: .init(
                    choice: ChoiceValue(UInt64(2), tag: value.choice.tag),
                    validRange: value.validRange,
                    isRangeExplicit: value.isRangeExplicit
                ))
                var copied = original
                copied[index] = .value(replacement.value)
                for ceiling in [nil, original.count, 1] {
                    let shared = Materializer.guidedLift(
                        generator: generator.erase(), prefix: original, fallbackTree: tree,
                        maximumSequenceCount: ceiling, valueReplacement: replacement
                    )
                    let eager = Materializer.guidedLift(
                        generator: generator.erase(), prefix: copied, fallbackTree: tree,
                        maximumSequenceCount: ceiling
                    )
                    #expect(shared.map { ChoiceSequence($0) } == eager.map { ChoiceSequence($0) })
                }
            }
            count += 1
        }
        #expect(count == 10)
    }
}
