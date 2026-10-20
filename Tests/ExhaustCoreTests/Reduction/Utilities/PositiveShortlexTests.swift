import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Positive-first shortlex")
struct PositiveShortlexTests {
    @Test("Signed endpoints and zero take positive-first keys", arguments: [TypeTag.int8, .int16, .int32, .int64, .int])
    func signedEndpoints(tag: TypeTag) {
        let maximum = tag.bitPatternRange.upperBound
        let zero = tag.simplestBitPattern
        #expect(ChoiceValue(UInt64(0), tag: tag).shortlexKey == maximum)
        #expect(ChoiceValue(maximum, tag: tag).shortlexKey == maximum - 2)
        #expect(ChoiceValue(UInt64(1), tag: tag).shortlexKey == maximum - 1)
        #expect(ChoiceValue(zero + 1, tag: tag).shortlexKey == 1)
        #expect(ChoiceValue(zero - 1, tag: tag).shortlexKey == 2)
    }

    @Test("Positive floats precede their negative counterparts, including zeros and infinities", arguments: [TypeTag.double, .float, .float16])
    func floatingSigns(tag: TypeTag) throws {
        for magnitude in [0.0, 1.0, 1.5, Double.infinity] {
            let positive = try #require(tag.floatingChoice(from: magnitude, allowNonFinite: true))
            let negative = try #require(tag.floatingChoice(from: -magnitude, allowNonFinite: true))
            #expect(positive.shortlexKey == negative.shortlexKey)
            #expect(positive.shortLexCompare(negative) == .lt)
            #expect(negative.shortLexCompare(positive) == .gt)
            let positiveEntry = ChoiceSequenceValue.Value(choice: positive, validRange: nil, isRangeExplicit: false)
            let negativeEntry = ChoiceSequenceValue.Value(choice: negative, validRange: nil, isRangeExplicit: false)
            #expect(positiveEntry.shortLexCompare(negativeEntry) == .lt)
        }
    }

    @Test("NaN ordering preserves sign preference and distinguishes payloads", arguments: [TypeTag.double, .float, .float16])
    func nanSignsAndPayloads(tag: TypeTag) throws {
        let positive = try #require(tag.floatingChoice(from: .nan, allowNonFinite: true))
        let negative = ChoiceValue(~positive.bitPattern64 & tag.bitPatternRange.upperBound, tag: tag)
        let otherPayload = ChoiceValue(positive.bitPattern64 + 1, tag: tag)
        #expect(negative.decodedDoubleValue.isNaN)
        #expect(otherPayload.decodedDoubleValue.isNaN)
        #expect(positive.shortLexCompare(negative) == .lt)
        #expect(negative.shortLexCompare(positive) == .gt)
        #expect(positive.shortLexCompare(otherPayload) == .lt)
        #expect(otherPayload.shortLexCompare(positive) == .gt)
        #expect(positive.shortLexCompare(positive) == .eq)
    }

    @Test("Shortlex comparison stays total and transitive over arbitrary representations", arguments: [
        TypeTag.int8, .int64, .uint64, .double, .float, .float16,
    ])
    func orderingLaws(tag: TypeTag) throws {
        let patterns = Gen.zip(Gen.choose() as Generator<UInt64>, Gen.choose() as Generator<UInt64>, Gen.choose() as Generator<UInt64>)
        try exhaustCheck(patterns, maxIterations: 1000) { first, second, third in
            let maximum = tag.bitPatternRange.upperBound
            let values = [first, second, third].map { ChoiceValue($0 & maximum, tag: tag) }
            let forward = values[0].shortLexCompare(values[1])
            let backward = values[1].shortLexCompare(values[0])
            let isSymmetric = switch forward {
                case .lt:
                    backward == .gt
                case .gt:
                    backward == .lt
                case .eq:
                    backward == .eq && values[0] == values[1]
            }
            guard isSymmetric else {
                return false
            }
            if forward == .lt, values[1].shortLexCompare(values[2]) == .lt {
                return values[0].shortLexCompare(values[2]) == .lt
            }
            return true
        }
    }
}
