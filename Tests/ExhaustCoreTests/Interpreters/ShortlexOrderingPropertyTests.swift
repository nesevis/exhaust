import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Shortlex Ordering Properties")
struct ShortlexOrderingPropertyTests {
    private static func sameTagPairGen(tag: TypeTag) -> Generator<(ChoiceValue, ChoiceValue)> {
        Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max),
            Gen.choose(in: UInt64.min ... UInt64.max)
        ).map { (pair: (UInt64, UInt64)) in
            (ChoiceValue(pair.0, tag: tag), ChoiceValue(pair.1, tag: tag))
        }
    }

    private static func sameTagTripleGen(tag: TypeTag) -> Generator<(ChoiceValue, ChoiceValue, ChoiceValue)> {
        Gen.zip(
            Gen.choose(in: UInt64.min ... UInt64.max),
            Gen.zip(
                Gen.choose(in: UInt64.min ... UInt64.max),
                Gen.choose(in: UInt64.min ... UInt64.max)
            )
        ).map { (outer: (UInt64, (UInt64, UInt64))) in
            (ChoiceValue(outer.0, tag: tag), ChoiceValue(outer.1.0, tag: tag), ChoiceValue(outer.1.1, tag: tag))
        }
    }

    @Test("Comparison is total within each type tag",
          arguments: [TypeTag.uint64, .int64, .double])
    func totality(tag: TypeTag) throws {
        try exhaustCheck(Self.sameTagPairGen(tag: tag), maxIterations: 300) { pair in
            let (a, b) = pair
            let aLessB = a < b
            let bLessA = b < a
            let equal = a == b
            return [aLessB, bLessA, equal].count(where: { $0 }) == 1
        }
    }

    @Test("Comparison is transitive within each type tag",
          arguments: [TypeTag.uint64, .int64, .double])
    func transitivity(tag: TypeTag) throws {
        try exhaustCheck(Self.sameTagTripleGen(tag: tag), maxIterations: 300) { triple in
            let (a, b, c) = triple
            if a < b, b < c {
                return a < c
            }
            return true
        }
    }

    @Test("Comparison is antisymmetric within each type tag",
          arguments: [TypeTag.uint64, .int64, .double])
    func antisymmetry(tag: TypeTag) throws {
        try exhaustCheck(Self.sameTagPairGen(tag: tag), maxIterations: 300) { pair in
            let (a, b) = pair
            if a < b {
                return (b < a) == false
            }
            return true
        }
    }
}
