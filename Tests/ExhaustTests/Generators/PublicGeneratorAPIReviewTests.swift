import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

@Suite("Public generator API review regressions")
struct PublicGeneratorAPIReviewTests {
    @Test("Qualified static factories generate but reject enum-case reflection")
    func qualifiedStaticFactoryRejectsEnumCaseReflection() throws {
        let generator = #gen(.int(in: 0 ... 10)) { value in
            ReviewFactory.make(value: value)
        }
        let target = ReviewProduct(value: 7)
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator.gen,
            seed: 0,
            maxRuns: 1
        )

        let (generated, _) = try #require(try interpreter.next())

        #expect((0 ... 10).contains(generated.value))
        #expect(throws: ReflectionError.contramapWasWrongType) {
            try Interpreters.reflect(generator.gen, with: target)
        }
    }

    @Test("Qualified enum cases reflect their associated values")
    func qualifiedEnumCaseReflectsAssociatedValues() throws {
        let generator = #gen(.just("seven"), .just(7)) { text, number in
            ReviewEnum.pair(number: number, text: text)
        }
        let target = ReviewEnum.pair(number: 7, text: "seven")

        let tree = try #require(
            try Interpreters.reflect(generator.gen, with: target)
        )
        let replayed = try #require(
            try Interpreters.replay(generator.gen, using: tree)
        )

        #expect(replayed == target)
    }

    @Test("Single tuple enum payloads reflect as one value")
    func singleTupleEnumPayloadsReflectAsOneValue() throws {
        let cases: [(generator: ReflectiveGenerator<ReviewEnum>, target: ReviewEnum)] = [
            (
                generator: #gen(.just((3, 7))) { coordinates in
                    ReviewEnum.point(coordinates)
                },
                target: .point((3, 7))
            ),
            (
                generator: #gen(.just((5, 11))) { coordinates in
                    ReviewEnum.labeledPoint(coordinates: coordinates)
                },
                target: .labeledPoint(coordinates: (5, 11))
            ),
        ]

        for testCase in cases {
            let tree = try #require(
                try Interpreters.reflect(testCase.generator.gen, with: testCase.target)
            )
            let replayed = try #require(
                try Interpreters.replay(testCase.generator.gen, using: tree)
            )

            #expect(replayed == testCase.target)
        }
    }

    @Test("An escaped enum case name matches its Mirror label")
    func escapedEnumCaseNameReflects() throws {
        // swiftformat:disable redundantBackticks
        let generator = #gen(.just(11)) { value in
            ReviewEnum.`default`(value)
        }
        let target = ReviewEnum.`default`(11)
        // swiftformat:enable redundantBackticks

        let tree = try #require(
            try Interpreters.reflect(generator.gen, with: target)
        )
        let replayed = try #require(
            try Interpreters.replay(generator.gen, using: tree)
        )

        #expect(replayed == target)
    }

    @Test("getSize reflects through the maximum size")
    func getSizeReflectsThroughMaximumSize() throws {
        let generator = #gen(.getSize { size in
            .uint64(in: 0 ... size)
        })
        let target: UInt64 = 73

        let tree = try #require(
            try Interpreters.reflect(generator.gen, with: target)
        )
        let replayed = try #require(
            try Interpreters.replay(generator.gen, using: tree)
        )

        #expect(replayed == target)
    }

    @Test("Pick reflection rejects a bound branch whose inner generator cannot produce the target")
    func pickReflectionRejectsInconsistentBoundBranch() throws {
        let dependentGenerator = #gen(.just(0)).bound(
            forward: { value in .just(value) },
            backward: { value in value }
        )
        let generator = #gen(.oneOf(dependentGenerator, .just(1)))
        let target = 1

        let tree = try #require(
            try Interpreters.reflect(generator.gen, with: target)
        )
        let replayed = try #require(
            try Interpreters.replay(generator.gen, using: tree)
        )

        #expect(replayed == target)
    }

    @Test("A bound generator over a zip exactly materializes its generated witness")
    func boundZipExactlyMaterializesGeneratedWitness() throws {
        let generator = #gen(
            .int(in: 0 ... 0),
            .int(in: 0 ... 0)
        ) { first, second in
            ReviewPair(first: first, second: second)
        }.bound(
            forward: { value in .just(value) },
            backward: { value in value }
        )
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator.gen,
            seed: 0,
            maxRuns: 1
        )
        let (value, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence.flatten(tree)

        switch Materializer.materialize(
            generator.gen,
            prefix: sequence,
            mode: .exact,
            fallbackTree: tree
        ) {
            case let .success(materialized, freshTree, _):
                #expect(materialized == value)
                #expect(ChoiceSequence.flatten(freshTree) == sequence)
            case .rejected, .failed:
                Issue.record("Exact materialization rejected a generated witness")
        }
    }

    @Test("A resized zip exactly materializes its generated witness")
    func resizedZipExactlyMaterializesGeneratedWitness() throws {
        let generator = #gen(
            .just(0),
            .int(in: 0 ... 0)
        ).resize(1)
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator.gen,
            seed: 0,
            maxRuns: 1
        )
        let (value, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence.flatten(tree)

        switch Materializer.materialize(
            generator.gen,
            prefix: sequence,
            mode: .exact,
            fallbackTree: tree
        ) {
            case let .success(materialized, freshTree, _):
                #expect(materialized == value)
                #expect(ChoiceSequence.flatten(freshTree) == sequence)
            case .rejected, .failed:
                Issue.record("Exact materialization rejected a resized zip witness")
        }
    }

    @Test("Fixed-prefix Data overloads reject reflection targets outside their domains")
    func fixedPrefixDataRejectsMismatchedPrefix() throws {
        let generators: [ReflectiveGenerator<Data>] = [
            #gen(.data(prefix: [0xCA, 0xFE])),
            #gen(.data(prefix: [0xCA, 0xFE], length: 1 ... 3)),
            #gen(.data(prefix: [0xCA, 0xFE], length: 2)),
        ]
        let mismatched = Data([0xBA, 0xAD, 0x01, 0x02])

        for generator in generators {
            let tree = try Interpreters.reflect(generator.gen, with: mismatched)
            #expect(tree == nil)
        }
    }

    @Test("UUID reflection accepts Foundation values and canonicalizes them to v4")
    func uuidReflectionMatchesFoundationRepresentableDomain() throws {
        let generator = #gen(.uuid())
        let uuidStrings = [
            "00000000-0000-0000-0000-000000000000",
            "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
        ]

        for uuidString in uuidStrings {
            let target = try #require(UUID(uuidString: uuidString))
            let tree = try #require(
                try Interpreters.reflect(generator.gen, with: target)
            )
            let replayed = try #require(
                try Interpreters.replay(generator.gen, using: tree)
            )
            let targetBytes = withUnsafeBytes(of: target.uuid) { Array($0) }
            let replayedBytes = withUnsafeBytes(of: replayed.uuid) { Array($0) }

            for index in targetBytes.indices {
                switch index {
                    case 6:
                        #expect(replayedBytes[index] & 0x0F == targetBytes[index] & 0x0F)
                        #expect(replayedBytes[index] >> 4 == 0x4)
                    case 8:
                        #expect(replayedBytes[index] & 0x3F == targetBytes[index] & 0x3F)
                        #expect(replayedBytes[index] >> 6 == 0b10)
                    default:
                        #expect(replayedBytes[index] == targetBytes[index])
                }
            }
        }
    }
}

private struct ReviewProduct: Equatable {
    let value: Int
}

private struct ReviewPair: Equatable {
    let first: Int
    let second: Int
}

private enum ReviewFactory {
    static func make(value: Int) -> ReviewProduct {
        ReviewProduct(value: value)
    }
}

private enum ReviewEnum: Equatable {
    case pair(number: Int, text: String)
    case point((Int, Int))
    case labeledPoint(coordinates: (Int, Int))
    case `default`(Int)

    static func == (left: Self, right: Self) -> Bool {
        switch (left, right) {
            case let (.pair(leftNumber, leftText), .pair(rightNumber, rightText)):
                leftNumber == rightNumber && leftText == rightText
            case let (.point(leftCoordinates), .point(rightCoordinates)):
                leftCoordinates.0 == rightCoordinates.0
                    && leftCoordinates.1 == rightCoordinates.1
            case let (.labeledPoint(leftCoordinates), .labeledPoint(rightCoordinates)):
                leftCoordinates.0 == rightCoordinates.0
                    && leftCoordinates.1 == rightCoordinates.1
            case let (.default(leftValue), .default(rightValue)):
                leftValue == rightValue
            default:
                false
        }
    }
}
