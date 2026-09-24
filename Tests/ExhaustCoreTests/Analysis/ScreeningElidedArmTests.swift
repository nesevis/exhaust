import Testing
@testable import ExhaustCore

@Suite("Screening elided arms")
struct ScreeningElidedArmTests {
    @Test("A pick whose unselected arm binds is never an exhaustive candidate")
    func bindingArmPreventsExhaustiveCandidacy() throws {
        // Shaped like the recursive generators that first exposed this: a payload-free arm beside one whose
        // shape depends on a drawn value. Screening analysis records only the arm it selected, so when it
        // selects the payload-free one the template holds no evidence that the other arm exists.
        let binding = Gen.choose(in: UInt64(0) ... 3).wrapped(isReflective: true).bind { value in
            ReflectiveGenerator<UInt64>.just(value)
        }.gen
        let generator = Gen.pick(choices: [
            (weight: 1, generator: Gen.just(UInt64(0))),
            (weight: 7, generator: binding),
        ])
        let plan = try #require(ScreeningRunner.plan(generator, screeningBudget: 200))
        #expect(plan.isExhaustiveCandidate == false)
    }

    @Test("A pick whose arms are all bind-free remains an exhaustive candidate")
    func bindFreeArmsRemainExhaustive() throws {
        // The positive control: eliding these arms loses nothing, so the domain really is swept by its rows.
        let generator = Gen.pick(choices: [
            (weight: 1, generator: Gen.just(UInt64(0))),
            (weight: 1, generator: Gen.just(UInt64(1))),
        ])
        let plan = try #require(ScreeningRunner.plan(generator, screeningBudget: 200))
        #expect(plan.isExhaustiveCandidate)
    }

    @Test("A generator with a choice outside the parameter model is never an exhaustive candidate", arguments: UnmodeledChoiceShape.allCases)
    func unmodeledChoicePreventsExhaustiveCandidacy(shape: UnmodeledChoiceShape) throws {
        let plan = try #require(ScreeningRunner.plan(shape.generator, screeningBudget: 2000))
        #expect(plan.isExhaustiveCandidate == false)
    }

    @Test("A generator whose every choice is a modeled parameter remains an exhaustive candidate", arguments: FullyModeledShape.allCases)
    func fullyModeledShapeRemainsExhaustive(shape: FullyModeledShape) throws {
        let plan = try #require(ScreeningRunner.plan(shape.generator, screeningBudget: 2000))
        #expect(plan.isExhaustiveCandidate)
    }

    @Test("Rows the materializer does not honor withhold the exhaustive verdict")
    func repeatedRowsWithholdTheVerdict() {
        // A filter over a continuation-built choice loses the row's value, so the rows repeat points of the domain instead of sweeping it.
        let dependent = Gen.just(UInt64(21)).bind { low in Gen.choose(in: low ... low + 50) }
        let filtered: Generator<UInt64> = .impure(
            operation: .filter(
                gen: dependent.erase(),
                fingerprint: 1,
                filterType: .rejectionSampling,
                predicate: { _ in true },
                sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
            ),
            continuation: { .pure($0 as! UInt64) }
        )
        var distinctRows = Set<UInt64>()
        let result = ScreeningRunner.run(filtered, screeningBudget: 512, coveringSeed: 0, property: { value in
            distinctRows.insert(value)
            return true
        })
        guard case .partial = result else {
            Issue.record("Expected a partial result, got \(result)")
            return
        }
        #expect(distinctRows.count < 51)
    }

    @Test("Collection combinators that build on a drawn collection record a bind", arguments: DrawnCollectionCombinator.allCases)
    func drawnCollectionCombinatorsRecordBind(combinator: DrawnCollectionCombinator) throws {
        // Both draw a collection and then build a generator shaped by it. Recorded as a bind node, that dependence withholds the exhaustive verdict and keeps the callee-continuation pair out of the tree; built on the invisible bind it would do neither.
        var interpreter = ValueAndChoiceTreeInterpreter(combinator.generator, seed: 1337, maxRuns: 1, sizeOverride: 100)
        let (_, tree) = try #require(try interpreter.next())
        #expect(tree.containsBind)
    }

    @Test("The graph walk reports every draw it can see")
    func graphWalkReportsDraws() {
        #expect(Gen.just(UInt64(0)).drawsChoice == false)
        #expect(Gen.choose(in: UInt64(4) ... 4).drawsChoice == false)
        #expect(Gen.zip(Gen.just(UInt64(0)), Gen.just(UInt64(1))).drawsChoice == false)
        #expect(Gen.pick(choices: [(1, Gen.just(UInt64(0)))]).drawsChoice == false)

        #expect(Gen.choose(in: UInt64(0) ... 3).drawsChoice)
        #expect(Gen.pick(choices: [(1, Gen.just(UInt64(0))), (1, Gen.just(UInt64(1)))]).drawsChoice)
        #expect(Gen.zip(Gen.just(UInt64(0)), Gen.choose(in: UInt64(0) ... 3)).drawsChoice)
        #expect(Gen.arrayOf(Gen.just(UInt64(0)), exactly: 2).drawsChoice)
        #expect(Gen.getSize { Gen.just($0) }.drawsChoice)
    }
}

// MARK: - Supporting Types

/// Shapes that draw somewhere screening does not count: inside a pick arm, inside an opaque zip, or behind a size read.
enum UnmodeledChoiceShape: CaseIterable, CustomTestStringConvertible {
    case drawingArms
    case drawingArmFavored
    case constantArmFavored
    case nestedPickArm
    case sequenceArm
    case sizeReadingArm
    case continuationBuiltArm
    case backtrackArms
    case backtrackUnmaterializableArm
    case opaqueZip

    var testDescription: String {
        "\(self)"
    }

    var generator: Generator<UInt64> {
        let large = Gen.choose(in: UInt64(0) ... 20000)
        let constant = Gen.just(UInt64(0))
        switch self {
            case .drawingArms:
                return Gen.pick(choices: [(1, large), (1, Gen.choose(in: UInt64(30000) ... 50000))])
            case .drawingArmFavored:
                return Gen.pick(choices: [(1, constant), (1000, large)])
            case .constantArmFavored:
                return Gen.pick(choices: [(1000, constant), (1, large)])
            case .nestedPickArm:
                return Gen.pick(choices: [(1, constant), (1, Gen.pick(choices: [(1, constant), (1, Gen.just(UInt64(1)))]))])
            case .sequenceArm:
                return Gen.pick(choices: [(1, constant), (1, Gen.arrayOf(large, exactly: 2).map { $0[0] })])
            case .sizeReadingArm:
                return Gen.pick(choices: [(1, constant), (1, Gen.getSize { Gen.just($0) })])
            case .continuationBuiltArm:
                return Gen.pick(choices: [(1000, constant), (1, constant.bind { _ in large })])
            case .backtrackArms:
                return Gen.backtrack(always: [(1, large.map { Optional($0) }), (1, constant.map { Optional($0) })])
            case .backtrackUnmaterializableArm:
                // The second element repeats the first, so recording the unselected arm exhausts the unique budget and leaves no subtree to judge it by.
                let duplicating = Gen.just(UInt64(4)).wrapped(isReflective: true).unique().gen
                let unmaterializable = Gen.arrayOf(duplicating, exactly: 2).map { Optional($0[0]) }
                return Gen.backtrack(always: [(1000, constant.map { Optional($0) }), (1, unmaterializable)])
            case .opaqueZip:
                return Gen.zip(Gen.choose(in: UInt64(0) ... 1), Gen.zip(constant, large, isOpaque: true).map { $0 + $1 }).map { $0 + $1 }
        }
    }
}

enum DrawnCollectionCombinator: CaseIterable, CustomTestStringConvertible {
    case shuffled
    case slice

    var testDescription: String {
        "\(self)"
    }

    var generator: Generator<[UInt64]> {
        let source = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 3), exactly: 4)
        switch self {
            case .shuffled:
                return Gen.shuffled(source)
            case .slice:
                return Gen.slice(of: source).map { Array($0) }
        }
    }
}

/// Shapes whose rows are the whole domain, so the verdict has to survive.
enum FullyModeledShape: CaseIterable, CustomTestStringConvertible {
    case constantArms
    case singleValueRangeArm
    case constantBacktrackArms
    case smallChoices
    case constantOpaqueZip

    var testDescription: String {
        "\(self)"
    }

    var generator: Generator<UInt64> {
        let constant = Gen.just(UInt64(0))
        switch self {
            case .constantArms:
                return Gen.pick(choices: [(1, constant), (1, Gen.just(UInt64(1))), (1, Gen.just(UInt64(2)))])
            case .singleValueRangeArm:
                return Gen.pick(choices: [(1, constant), (1, Gen.choose(in: UInt64(7) ... 7))])
            case .constantBacktrackArms:
                return Gen.backtrack(always: [(1, constant.map { Optional($0) }), (1, Gen.just(UInt64(1)).map { Optional($0) })])
            case .smallChoices:
                return Gen.zip(Gen.choose(in: UInt64(0) ... 3), Gen.choose(in: UInt64(0) ... 9)).map { $0 + $1 }
            case .constantOpaqueZip:
                return Gen.zip(Gen.choose(in: UInt64(0) ... 3), Gen.zip(constant, constant, isOpaque: true).map { $0 + $1 }).map { $0 + $1 }
        }
    }
}
