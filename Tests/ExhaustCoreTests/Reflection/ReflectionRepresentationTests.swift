import ExhaustCore
import Testing

@Suite("Reflection representation precedence")
struct ReflectionRepresentationTests {
    @Test("Explicit bit patterns take precedence over sequence cardinality")
    func explicitRepresentation() throws {
        let generator = Gen.choose(type: SequenceBits.self)
        let target = SequenceBits(bitPattern64: 7)
        let tree = try #require(try Interpreters.reflect(generator, with: target))
        guard case let .choice(value, _) = tree else {
            Issue.record("Expected one reflected numeric choice")
            return
        }
        #expect(value.bitPattern64 == 7)
    }
}

/// Deliberately supplies distinct numeric and sequence representations so reflection cannot silently substitute cardinality for the encoded value.
private struct SequenceBits: BitPatternConvertible, Sequence, Comparable {
    static let bitPatternRange: ClosedRange<UInt64> = 0 ... 10
    static let tag: TypeTag = .uint64
    static var defaultScaling: SizeScaling<Self> {
        .constant
    }

    let bitPattern64: UInt64
    var underestimatedCount: Int {
        2
    }

    func makeIterator() -> IndexingIterator<[UInt64]> {
        [0, 1].makeIterator()
    }

    static func < (left: Self, right: Self) -> Bool {
        left.bitPattern64 < right.bitPattern64
    }
}
