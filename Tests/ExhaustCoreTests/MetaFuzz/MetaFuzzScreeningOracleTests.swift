import ExhaustCore
import ExhaustMetaFuzz
import Foundation
import Testing

/// Coverage for the screening campaign's roster. The classification table pins the reference model and the engine against each other shape by shape; the sweeps run the whole roster the way the fuzz campaign does.
@Suite("MetaFuzz screening oracles")
struct MetaFuzzScreeningOracleTests {
    @Test("The reference model classifies each recipe shape", arguments: ScreeningShape.allCases)
    func referenceModelClassifiesShape(shape: ScreeningShape) {
        #expect(shape.recipe.screeningExpectation == shape.expectation)
    }

    @Test("Screening agrees with the reference model on each recipe shape", arguments: ScreeningShape.allCases, MetaFuzz.screeningBudgets.indices)
    func screeningAgreesOnShape(shape: ScreeningShape, budgetIndex: Int) throws {
        let outcome = try MetaFuzz.checkScreening(MetaFuzzCase(
            recipe: shape.recipe,
            valueSeed: 1337,
            perturbationSeed: UInt64(budgetIndex)
        ))
        let budget = MetaFuzz.screeningBudgets[budgetIndex]
        switch shape.expectation {
            case let .enumerable(points) where points <= budget:
                #expect(outcome == .exhaustive)
            case .constant:
                #expect(outcome == .notApplicable)
            case .enumerable, .notEnumerable:
                #expect(outcome != .exhaustive)
            case .unspecified:
                break
        }
    }

    @Test("No screening oracle fires on healthy code across generated cases", arguments: [1, 2, 3])
    func screeningOraclesHoldOnHealthyCode(maxDepth: Int) throws {
        let caseGenerator = MetaFuzz.caseGenerator(maxDepth: maxDepth)
        var iterator = ValueInterpreter(caseGenerator.gen, seed: 42, maxRuns: 600)
        var outcomes: [MetaFuzz.ScreeningOutcome: Int] = [:]
        var settled = 0
        while let fuzzCase = try iterator.next() {
            do {
                try outcomes[MetaFuzz.checkScreening(fuzzCase), default: 0] += 1
            } catch {
                Issue.record("Screening oracle fired on healthy code: \(error)")
                return
            }
            if fuzzCase.recipe.screeningExpectation != .unspecified {
                settled += 1
            }
        }
        // A sweep that never reaches a verdict, or that the reference model never settles, checks nothing.
        #expect(outcomes[.exhaustive, default: 0] > 0)
        #expect(outcomes[.partial, default: 0] > 0)
        #expect(settled > 0)
    }

    @Test("A screening finding freezes and replays through the screening roster")
    func screeningFindingRoundTrips() throws {
        let fuzzCase = MetaFuzzCase(recipe: .leaf(.bool), valueSeed: 1, perturbationSeed: 2)
        let data = try MetaFuzz.freeze(
            fuzzCase,
            kind: .screeningCase,
            violation: ExhaustiveVerdictSoundnessViolation("synthetic")
        )
        let record = try JSONDecoder().decode(MetaFuzzFrozenCase.self, from: data)
        #expect(record.kind == .screeningCase)
        #expect(record.oracle == "ExhaustiveVerdictSoundnessViolation")
        try MetaFuzz.replay(data)
    }
}

// MARK: - Supporting Types

/// One recipe per grammar rule the reference model settles, on both sides of each boundary.
enum ScreeningShape: CaseIterable, CustomTestStringConvertible {
    case bool
    case smallRange
    case widestEnumerableRange
    case narrowestLargeRange
    case singleValueRange
    case constant
    case double
    case singleValueDouble
    case adjacentDoubles
    case signedZeroDoubles
    case string
    case character
    case zipOfEnumerables
    case zipWithConstant
    case zipWithLargeRange
    case eachOfEnumerables
    case mappedEnumerable
    case filteredAlways
    case classifiedEnumerable
    case resizedEnumerable
    case constantArms
    case weightedConstantArms
    case optionalConstant
    case drawingArm
    case optionalEnumerable
    case optionalLargeRange
    case nestedDrawingArm
    case constantBacktrackArms
    case failableConstantBacktrackArms
    case drawingBacktrackArm
    case array
    case fixedLengthArray
    case boundArray
    case reifiedBind
    case sizeRead
    case boundRange
    case rejectingFilter

    var testDescription: String {
        "\(self)"
    }

    var recipe: GenRecipe {
        let bool = GenRecipe.leaf(.bool)
        let small = GenRecipe.leaf(.int(0 ... 9))
        let large = GenRecipe.leaf(.int(0 ... 20000))
        let one = GenRecipe.leaf(.justInt(1))
        let two = GenRecipe.leaf(.justInt(2))
        switch self {
            case .bool:
                return bool
            case .smallRange:
                return small
            case .widestEnumerableRange:
                return .leaf(.int(0 ... 255))
            case .narrowestLargeRange:
                return .leaf(.int(0 ... 256))
            case .singleValueRange:
                return .leaf(.int(4 ... 4))
            case .constant:
                return one
            case .double:
                return .leaf(.double(0 ... 1))
            case .singleValueDouble:
                return .leaf(.double(0 ... 0))
            case .adjacentDoubles:
                return .leaf(.double(1.0 ... 1.0.nextUp))
            case .signedZeroDoubles:
                return .leaf(.double(-0.0 ... 0.0))
            case .string:
                return .leaf(.string(0 ... 3))
            case .character:
                return .leaf(.character)
            case .zipOfEnumerables:
                return .combinator(.zipped(small, bool))
            case .zipWithConstant:
                return .combinator(.zipped(small, one))
            case .zipWithLargeRange:
                return .combinator(.zipped(small, large))
            case .eachOfEnumerables:
                return .combinator(.eachOf([small, small, small]))
            case .mappedEnumerable:
                return .combinator(.mapped(small, .increment))
            case .filteredAlways:
                return .combinator(.filtered(small, .always))
            case .classifiedEnumerable:
                return .combinator(.classified(small))
            case .resizedEnumerable:
                return .combinator(.resized(small, size: 10))
            case .constantArms:
                return .combinator(.oneOf([one, two, .leaf(.justInt(3))]))
            case .weightedConstantArms:
                return .combinator(.weightedOneOf([.init(weight: 1, recipe: one), .init(weight: 9, recipe: two)]))
            case .optionalConstant:
                return .combinator(.optional(one))
            case .drawingArm:
                return .combinator(.oneOf([one, small]))
            case .optionalEnumerable:
                return .combinator(.optional(small))
            case .optionalLargeRange:
                return .combinator(.optional(large))
            case .nestedDrawingArm:
                return .combinator(.oneOf([one, .combinator(.oneOf([two, small]))]))
            case .constantBacktrackArms:
                return .combinator(.backtrack([.init(weight: 1, recipe: one, predicate: .always), .init(weight: 1, recipe: two, predicate: .always)], failable: false))
            case .failableConstantBacktrackArms:
                return .combinator(.backtrack([.init(weight: 1, recipe: one, predicate: .always), .init(weight: 1, recipe: two, predicate: .always)], failable: true))
            case .drawingBacktrackArm:
                return .combinator(.backtrack([.init(weight: 1, recipe: one, predicate: .always), .init(weight: 1, recipe: small, predicate: .always)], failable: false))
            case .array:
                return .combinator(.array(bool, lengthRange: 0 ... 3))
            case .fixedLengthArray:
                return .combinator(.array(bool, lengthRange: 2 ... 2))
            case .boundArray:
                return .combinator(.boundArray(element: small, maxLength: 3))
            case .reifiedBind:
                return .combinator(.reifiedBind(small))
            case .sizeRead:
                return .combinator(.getSized)
            case .boundRange:
                return .combinator(.boundRange(one))
            case .rejectingFilter:
                return .combinator(.filtered(small, .isEven))
        }
    }

    var expectation: ScreeningExpectation {
        switch self {
            case .bool:
                .enumerable(points: 2)
            case .smallRange, .mappedEnumerable, .filteredAlways, .classifiedEnumerable, .resizedEnumerable, .zipWithConstant:
                .enumerable(points: 10)
            case .widestEnumerableRange:
                .enumerable(points: 256)
            case .zipOfEnumerables:
                .enumerable(points: 20)
            case .eachOfEnumerables:
                .enumerable(points: 1000)
            case .constantArms, .failableConstantBacktrackArms:
                .enumerable(points: 3)
            case .weightedConstantArms, .optionalConstant, .constantBacktrackArms:
                .enumerable(points: 2)
            case .singleValueRange, .singleValueDouble:
                .enumerable(points: 1)
            case .constant:
                .constant
            case .narrowestLargeRange, .double, .string, .character, .zipWithLargeRange, .drawingArm, .optionalEnumerable, .optionalLargeRange, .nestedDrawingArm, .drawingBacktrackArm, .array, .fixedLengthArray, .boundArray, .boundRange, .reifiedBind, .sizeRead:
                .notEnumerable
            case .rejectingFilter, .adjacentDoubles, .signedZeroDoubles:
                .unspecified
        }
    }
}
