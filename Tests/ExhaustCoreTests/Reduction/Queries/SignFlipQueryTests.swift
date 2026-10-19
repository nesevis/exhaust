import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Numeric group sign flip")
struct SignFlipQueryTests {
    @Test("Signed widths flip signs in both directions exactly and reject their unpaired minimum", arguments: [TypeTag.int8, .int16, .int32, .int64, .int])
    func signedWidths(tag: TypeTag) throws {
        let zero = tag.simplestBitPattern
        let values = [zero - 1, zero + 3, UInt64(1), tag.bitPatternRange.upperBound, zero].map { ChoiceValue($0, tag: tag) }
        let probe = try #require(SignFlipQuery.build(leaves: leaves(values)))
        #expect(probe.patterns == [zero + 1, zero - 3, tag.bitPatternRange.upperBound, 1, zero])
        #expect(SignFlipQuery.build(leaves: leaves(values + [ChoiceValue(UInt64(0), tag: tag)])) == nil)
    }

    @Test("Floating sign flip preserves exact magnitudes and signed zeros in either direction", arguments: [TypeTag.double, .float, .float16])
    func floatingWidths(tag: TypeTag) throws {
        let values = [-1.0, 1.5, -Double.infinity, Double.infinity, 0.0, -0.0]
        let choices = values.map { ChoiceValue(tag.floatingBitPattern(from: $0), tag: tag) }
        let probe = try #require(SignFlipQuery.build(leaves: leaves(choices)))
        #expect(probe.patterns == values.map { tag.floatingBitPattern(from: -$0) })
        let invalid = ChoiceValue(tag.floatingBitPattern(from: .nan), tag: tag)
        #expect(SignFlipQuery.build(leaves: leaves(choices + [invalid])) == nil)
    }

    @Test("A sign flip is proposed exactly when it precedes the group in shortlex order", arguments: [TypeTag.int8, .int64, .double, .float16])
    func proposalsImproveShortlex(tag: TypeTag) throws {
        let patterns = Gen.zip(Gen.choose() as Generator<UInt64>, Gen.choose() as Generator<UInt64>)
        try exhaustCheck(patterns, maxIterations: 1000) { first, second in
            let values = [first, second].map { ChoiceValue($0 & tag.bitPatternRange.upperBound, tag: tag) }
            let probe = SignFlipQuery.build(leaves: leaves(values))
            let isFlippable = values.allSatisfy { value in
                value.signFlipped != nil && (tag.isFloatingPoint == false || value.decodedDoubleValue.isNaN == false)
            }
            guard isFlippable else {
                return probe == nil
            }
            let firstDifference = zip(values, values.compactMap(\.signFlipped))
                .map { original, flipped in flipped.shortLexCompare(original) }
                .first { $0 != .eq }
            return (probe != nil) == (firstDifference == .lt)
        }
    }

    @Test("Mixed integer and float operands flip signs only for the selected leaves")
    func mixedOperands() throws {
        let values = [
            ChoiceValue(Int64(-3), tag: .int64),
            ChoiceValue(1.0.nextUp.bitPattern64, tag: .double),
            ChoiceValue(Int64(17), tag: .int64),
        ]
        let selected = Array(leaves(values).prefix(2))
        let probe = try #require(SignFlipQuery.build(leaves: selected))
        #expect(probe.leaves.map(\.position) == [0, 1])
        #expect(probe.patterns == [Int64(3).bitPattern64, (-1.0.nextUp).bitPattern64])
        #expect(SignFlipQuery.build(leaves: selected + leaves([ChoiceValue(UInt64(2), tag: .uint64)])) == nil)
    }

    @Test("Domains reject the entire sign flip and unchanged integer zeros emit no proposal")
    func domainAndZero() {
        let values = [-3, -5].map { ChoiceValue(Int64($0), tag: .int64) }
        #expect(SignFlipQuery.build(leaves: leaves(values, range: Int64(-10).bitPattern64 ... Int64(-1).bitPattern64)) == nil)
        #expect(SignFlipQuery.build(leaves: leaves([ChoiceValue(Int64(0), tag: .int64)])) == nil)
        #expect(SignFlipQuery.build(leaves: []) == nil)
    }

    @Test("A stalled pair flips mixed signs while an unrelated positive value stays unchanged", arguments: [true, false])
    func reducerIntegration(acceptsSignFlip: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: -100 ... 100), within: 3 ... 3)
        let values = [-3, 5, 17]
        let signFlipped = [3, -5, 17]
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        var tuning = ReductionTuning()
        tuning.stagedJointProbeBudget = 1
        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: tree,
            output: values,
            config: .init(maxStalls: 2, enabledEncoders: [.valueSearch, .stagedJointSearch], tuning: tuning),
            property: { candidate in candidate != values && (acceptsSignFlip == false || candidate != signFlipped) }
        )
        #expect(result.outcome.counterexample?.1 == (acceptsSignFlip ? signFlipped : values))
        #expect(result.stats.encoderCounts[.stagedJointSearch]?.accepted == (acceptsSignFlip ? 1 : 0))
    }

    @Test("Replay rejects a sign flip that violates a generator filter")
    func generatorFilter() throws {
        let generator = Gen.filter(
            Gen.arrayOf(Gen.choose(in: -100 ... 100), within: 2 ... 2),
            type: .rejectionSampling,
            predicate: { $0.allSatisfy { $0 < 0 } },
            sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
        )
        let values = [-3, -5]
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        var tuning = ReductionTuning()
        tuning.stagedJointProbeBudget = 1
        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: tree,
            output: values,
            config: .init(maxStalls: 2, enabledEncoders: [.valueSearch, .stagedJointSearch], tuning: tuning),
            property: { $0 != values }
        )
        #expect(result.outcome.counterexample?.1 == values)
        #expect(result.stats.encoderCounts[.stagedJointSearch]?.propertyInvocations == 0)
        #expect(result.stats.encoderCounts[.stagedJointSearch]?.accepted == 0)
    }

    @Test("A pair whose signs cannot be flipped does not suppress another pair and sampled sign flips are not repeated")
    func selectedPairsAndDeduplication() throws {
        let values = [Int8.min, -1, 1].map { ChoiceValue($0, tag: .int8) }
        let members = leaves(values)
        let pairs = [
            NumericPairQuery.Pair(source: members[0], sink: members[1]),
            NumericPairQuery.Pair(source: members[1], sink: members[2]),
        ]
        var search = StagedJointSearch(pairs: pairs, base: [], probeBudget: 10000)
        var buffer: ChoiceSequence = []
        let first = try #require(search.next(.initial, into: &buffer))
        guard case let .sparse(signFlip, _, _) = first else {
            Issue.record("Expected a sparse sign flip")
            return
        }
        #expect(signFlip.leaves.map(\.position) == [1, 2])
        #expect(signFlip.patterns == [Int8(1).bitPattern64, Int8(-1).bitPattern64])
        while let candidate = search.next(.rejected(.propertyPassed), into: &buffer) {
            guard case let .sparse(probe, _, _) = candidate else {
                Issue.record("Expected sparse joint proposals")
                return
            }
            #expect(probe != signFlip)
        }
    }

    private func leaves(_ values: [ChoiceValue], range: ClosedRange<UInt64>? = nil) -> [ReductionLeaf] {
        values.enumerated().map { index, value in
            ReductionLeaf(nodeID: index, position: index, path: [], choice: value, range: range ?? value.tag.bitPatternRange, bindFingerprints: [], mayReshapeOnAcceptance: false)
        }
    }
}
