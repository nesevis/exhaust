import Testing
@testable import ExhaustCore

@Suite("ChoiceTree per-element segment decomposition")
struct ChoiceTreeCommandSegmentsTests {
    @Test("Extracts one segment per element from a Gen.arrayOf tree")
    func segmentCountMatchesElementCount() throws {
        let elementGen: Generator<Int> = Gen.choose(in: 0 ... 100)
        let arrayGen = Gen.arrayOf(elementGen, within: 4 ... 4, scaling: .constant)

        var interpreter = ValueAndChoiceTreeInterpreter(arrayGen, materializePicks: true, seed: 42, maxRuns: 1)
        let (value, tree) = try #require(try interpreter.next())

        let segments = try #require(tree.perElementSegments())
        #expect(segments.count == value.count)
        #expect(segments.count == 4)
    }

    @Test("Each segment is non-empty")
    func segmentsAreNonEmpty() throws {
        let elementGen: Generator<Int> = Gen.choose(in: 0 ... 10)
        let arrayGen = Gen.arrayOf(elementGen, within: 3 ... 3, scaling: .constant)

        var interpreter = ValueAndChoiceTreeInterpreter(arrayGen, materializePicks: true, seed: 7, maxRuns: 1)
        let (_, tree) = try #require(try interpreter.next())

        let segments = try #require(tree.perElementSegments())
        for segment in segments {
            #expect(segment.isEmpty == false)
        }
    }

    @Test("Concatenated segments reconstruct the sequence portion of the full flatten")
    func segmentsCoverTheSequenceContent() throws {
        let elementGen: Generator<Int> = Gen.choose(in: 0 ... 50)
        let arrayGen = Gen.arrayOf(elementGen, within: 3 ... 3, scaling: .constant)

        var interpreter = ValueAndChoiceTreeInterpreter(arrayGen, materializePicks: true, seed: 99, maxRuns: 1)
        let (_, tree) = try #require(try interpreter.next())

        let segments = try #require(tree.perElementSegments())
        let concatenated = segments.flatMap(\.self)

        let fullFlat = ChoiceSequence.flatten(tree)
        let sequenceContent = extractSequenceContent(from: fullFlat)

        #expect(concatenated.count == sequenceContent.count)
        for (segValue, fullValue) in zip(concatenated, sequenceContent) {
            #expect(segValue == fullValue)
        }
    }

    @Test("Pick-based element generator produces per-element segments")
    func pickBasedElementGenerator() throws {
        let elementGen: Generator<Int> = Gen.pick(choices: [
            (1, Gen.just(0)),
            (1, Gen.choose(in: 1 ... 10)),
        ])
        let arrayGen = Gen.arrayOf(elementGen, within: 5 ... 5, scaling: .constant)

        var interpreter = ValueAndChoiceTreeInterpreter(arrayGen, materializePicks: true, seed: 13, maxRuns: 1)
        let (value, tree) = try #require(try interpreter.next())

        let segments = try #require(tree.perElementSegments())
        #expect(segments.count == value.count)
    }

    @Test("Returns nil for a tree with no sequence node")
    func noSequenceReturnsNil() {
        let tree = ChoiceTree.choice(
            ChoiceValue(UInt64(42), tag: .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        #expect(tree.perElementSegments() == nil)
    }

    @Test("Identical elements produce identical segments")
    func identicalElementsProduceIdenticalSegments() throws {
        let elementGen: Generator<Int> = Gen.just(7)
        let arrayGen = Gen.arrayOf(elementGen, within: 3 ... 3, scaling: .constant)

        var interpreter = ValueAndChoiceTreeInterpreter(arrayGen, materializePicks: true, seed: 0, maxRuns: 1)
        let (_, tree) = try #require(try interpreter.next())

        let segments = try #require(tree.perElementSegments())
        #expect(segments.count == 3)
        #expect(segments[0] == segments[1])
        #expect(segments[1] == segments[2])
    }

    @Test("Different element values produce different segments")
    func differentValuesProduceDifferentSegments() throws {
        let elementGen: Generator<Int> = Gen.choose(in: 0 ... 1000)
        let arrayGen = Gen.arrayOf(elementGen, within: 3 ... 3, scaling: .constant)

        var interpreter = ValueAndChoiceTreeInterpreter(arrayGen, materializePicks: true, seed: 42, maxRuns: 1)
        let (value, tree) = try #require(try interpreter.next())

        let segments = try #require(tree.perElementSegments())

        if value[0] != value[1] {
            #expect(segments[0] != segments[1])
        }
    }
}

// MARK: - Helpers

/// Extracts the content between the first `.sequence(true)` and its matching `.sequence(false)` from a flat ChoiceSequence, excluding the markers themselves.
private func extractSequenceContent(from sequence: ChoiceSequence) -> ChoiceSequence {
    var result = ChoiceSequence()
    var inside = false
    var depth = 0
    for entry in sequence {
        switch entry {
            case .sequence(true, validRange: _, isLengthExplicit: _):
                if inside == false {
                    inside = true
                    depth = 1
                } else {
                    depth += 1
                    result.append(entry)
                }
            case .sequence(false, validRange: _, isLengthExplicit: _):
                depth -= 1
                if depth == 0 {
                    return result
                }
                result.append(entry)
            default:
                if inside {
                    result.append(entry)
                }
        }
    }
    return result
}
