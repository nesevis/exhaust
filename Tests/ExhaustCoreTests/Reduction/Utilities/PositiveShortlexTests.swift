import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Positive-first shortlex")
struct PositiveShortlexTests {
    @Test("Every narrow signed key round-trips without gaps", arguments: [TypeTag.int8, .int16])
    func exhaustiveSignedKeys(tag: TypeTag) {
        let maximum = tag.bitPatternRange.upperBound
        for key in UInt64(0) ... maximum {
            let choice = ChoiceValue.fromShortlexKey(key, tag: tag)
            #expect(choice.shortlexKey == key)
            #expect(choice.bitPattern64 <= maximum)
        }
    }

    @Test("Signed endpoints and zero retain reversible keys", arguments: [TypeTag.int8, .int16, .int32, .int64, .int])
    func signedEndpoints(tag: TypeTag) {
        let maximum = tag.bitPatternRange.upperBound
        let zero = tag.simplestBitPattern
        for pattern in [0, 1, zero - 1, zero, zero + 1, maximum - 1, maximum] {
            let choice = ChoiceValue(pattern, tag: tag)
            #expect(ChoiceValue.fromShortlexKey(choice.shortlexKey, tag: tag) == choice)
        }
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

    @Test("Numeric candidate admission shares the positive-first ordering", arguments: [TypeTag.int64, .double, .float, .float16])
    func numericCandidateSigns(tag: TypeTag) throws {
        let positive: ChoiceValue = switch tag {
            case .int64:
                ChoiceValue(Int64(1), tag: tag)
            default:
                try #require(tag.floatingChoice(from: 1))
        }
        let negative: ChoiceValue = switch tag {
            case .int64:
                ChoiceValue(Int64(-1), tag: tag)
            default:
                try #require(tag.floatingChoice(from: -1))
        }
        for current in [positive, negative] {
            let leaf = ReductionLeaf(
                nodeID: 0,
                position: 0,
                path: [],
                choice: current,
                range: tag.bitPatternRange,
                bindFingerprints: [],
                mayReshapeOnAcceptance: false
            )
            let candidates = NumericPairCandidates.jointValues(for: leaf, simplifying: true)
            #expect(candidates.contains(positive.bitPattern64) == (current == negative))
            #expect(candidates.contains(negative.bitPattern64) == false)
        }
    }

    @Test("Integer reduction can cross zero from a negative range endpoint", arguments: [-1 ... 1, -10 ... 10])
    func integerReductionPrefersPositive(range: ClosedRange<Int>) throws {
        let generator = Gen.choose(in: range)
        let output = try reduceFromReflection(
            generator,
            startingAt: range.lowerBound,
            config: .init(maxStalls: 2, enabledEncoders: [.valueSearch])
        ) { value in
            value == 0
        }
        #expect(output == 1)
    }

    @Test("Exhaustive integer covering visits positive ties first")
    func integerCoveringOrder() throws {
        let cases: [(ClosedRange<Int64>, [Int64])] = [
            (-2 ... 2, [0, 1, -1, 2, -2]),
            (-3 ... 1, [0, 1, -1, -2, -3]),
            (-3 ... -1, [-1, -2, -3]),
            (1 ... 3, [1, 2, 3]),
        ]
        for (range, expected) in cases {
            let initial = min(max(0, range.lowerBound), range.upperBound)
            let sequence = ChoiceSequence(.choice(
                ChoiceValue(initial, tag: .int64),
                .init(validRange: range.lowerBound.bitPattern64 ... range.upperBound.bitPattern64, isRangeExplicit: true)
            ))
            var rows = CoveringRows(tuning: .init(), rowCache: CoveringRowCache())
            rows.start(sequence: sequence, positions: [0])
            var values: [Int64] = []
            while let candidate = rows.nextProbe(lastAccepted: false) {
                try values.append(#require(candidate[0].value?.choice.decodedSignedValue))
            }
            #expect(values == expected)
        }
    }

    @Test("Float search offers positive counterparts for integral and fractional values", arguments: [-1.0, -1.5])
    func floatReductionPrefersPositive(initial: Double) throws {
        let generator = Gen.choose(in: -2.0 ... 2.0)
        let output = try reduceFromReflection(
            generator,
            startingAt: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.floatSearch])
        ) { value in
            value.magnitude != initial.magnitude
        }
        #expect(output == initial.magnitude)
    }

    @Test("Positive preference respects negative-only domains")
    func negativeOnlyRanges() throws {
        let integer = try reduceFromReflection(Gen.choose(in: -10 ... -1), startingAt: -10) { _ in false }
        let floating = try reduceFromReflection(Gen.choose(in: -10.0 ... -1.0), startingAt: -10.0) { _ in false }
        #expect(integer == -1)
        #expect(floating == -1)
    }
}
