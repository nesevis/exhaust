//
//  GenRecipe+ScreeningExpectation.swift
//  ExhaustMetaFuzz
//
//  The reference model for the screening oracles: what a recipe's shape says about whether screening may claim to have enumerated its whole domain.
//

// MARK: - Why a Separate Model

//
// ChoiceTreeAnalysis decides enumerability from an execution trace. This model decides it from the recipe grammar, which the analysis never sees, so an error in the trace walk cannot cancel against the same error here. It answers only where the grammar makes the answer certain and returns `.unspecified` everywhere else: an oracle built on a guess would report its own mistakes as engine defects.

/// What a recipe's grammar says screening can conclude about its domain.
package enum ScreeningExpectation: Equatable, Sendable, CustomStringConvertible {
    /// Draws nothing, so it contributes no parameter and one point.
    case constant
    /// Every draw is a root-level parameter of at most 256 values, and the rows of a run with at least `points` budget are the whole domain.
    case enumerable(points: UInt64)
    /// Some draw lies outside the parameter model or has more than 256 values, so random sampling must follow screening.
    case notEnumerable
    /// The grammar does not settle it.
    case unspecified

    package var description: String {
        switch self {
            case .constant:
                "constant"
            case let .enumerable(points):
                "enumerable(\(points))"
            case .notEnumerable:
                "notEnumerable"
            case .unspecified:
                "unspecified"
        }
    }
}

package extension GenRecipe {
    /// The largest parameter domain screening enumerates value by value.
    private static let enumerableParameterLimit: UInt64 = 256

    var screeningExpectation: ScreeningExpectation {
        switch self {
            case let .leaf(kind):
                Self.expectation(for: kind)
            case let .combinator(kind):
                Self.expectation(for: kind)
        }
    }

    private static func expectation(for leaf: LeafKind) -> ScreeningExpectation {
        switch leaf {
            case let .int(range):
                let (span, overflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
                guard overflow == false, UInt64(span) < enumerableParameterLimit else {
                    return .notEnumerable
                }
                // A single-value range still reifies as a one-point parameter.
                return .enumerable(points: UInt64(span) + 1)
            case .bool:
                return .enumerable(points: 2)
            case let .double(range):
                // Compared by bit pattern: `-0.0 ... 0.0` has equal bounds and two values.
                guard range.lowerBound.bitPattern != range.upperBound.bitPattern else {
                    return .enumerable(points: 1)
                }
                // A range a few representable values wide is enumerable by bit pattern, and counting those is the engine's encoding rather than the grammar's.
                var cursor = range.lowerBound
                for _ in 0 ..< enumerableParameterLimit where cursor < range.upperBound {
                    cursor = cursor.nextUp
                }
                return cursor < range.upperBound ? .notEnumerable : .unspecified
            case .string, .stringFromSet, .character:
                return .notEnumerable
            case .justInt, .justBool, .justDouble, .justIntArray:
                return .constant
        }
    }

    private static func expectation(for combinator: CombinatorKind) -> ScreeningExpectation {
        switch combinator {
            // Wrappers that neither draw nor reject pass the inner answer through.
            case let .contramapped(inner, _),
                 let .mapped(inner, _),
                 let .isomorphed(inner, _),
                 let .pruned(inner),
                 let .classified(inner),
                 let .resized(inner, _):
                return inner.screeningExpectation

            case let .filtered(inner, predicate):
                // A predicate that can reject turns rows into rejections, and whether it does depends on the values.
                return predicate == .always ? inner.screeningExpectation : .unspecified

            case let .zipped(first, second):
                return product(of: [first, second])

            case let .eachOf(recipes):
                return product(of: recipes)

            case let .oneOf(recipes):
                return choice(among: recipes.map(\.screeningExpectation), extraConstantArms: 0)

            case let .weightedOneOf(branches):
                return choice(among: branches.map(\.recipe.screeningExpectation), extraConstantArms: 0)

            case let .optional(inner):
                return choice(among: [inner.screeningExpectation], extraConstantArms: 1)

            case let .backtrack(arms, failable):
                guard arms.allSatisfy({ $0.predicate == .always }) else {
                    return .unspecified
                }
                // A failable node carries one more arm, the zero-weight absent outcome.
                return choice(among: arms.map(\.recipe.screeningExpectation), extraConstantArms: failable ? 1 : 0)

            // Sequences are composite parameters, which the enumerable profile never holds.
            case let .array(_, lengthRange), let .scaledArray(_, lengthRange, _):
                return lengthRange.upperBound == 0 ? .unspecified : .notEnumerable

            case .boundArray, .unfolded:
                return .notEnumerable

            // A reified bind and a size read both put a choice outside the model by construction.
            case .reifiedBind, .boundRange, .getSized:
                return .notEnumerable

            // Recursion, uniqueness budgets, and metamorphic copies each depend on details the grammar does not fix.
            case .recursive, .unique, .metamorphed:
                return .unspecified
        }
    }

    /// A product of parts is enumerable when every part is, and not enumerable as soon as one part is not.
    private static func product(of recipes: [GenRecipe]) -> ScreeningExpectation {
        var points: UInt64 = 1
        var isConstant = true
        var isSettled = true
        for recipe in recipes {
            switch recipe.screeningExpectation {
                case .constant:
                    continue
                case let .enumerable(partPoints):
                    isConstant = false
                    let (result, overflow) = points.multipliedReportingOverflow(by: partPoints)
                    points = overflow ? .max : result
                case .notEnumerable:
                    return .notEnumerable
                case .unspecified:
                    isSettled = false
            }
        }
        guard isSettled else {
            return .unspecified
        }
        return isConstant ? .constant : .enumerable(points: points)
    }

    /// A pick contributes its branch index alone, so it is enumerable only when no arm draws.
    private static func choice(
        among arms: [ScreeningExpectation],
        extraConstantArms: UInt64
    ) -> ScreeningExpectation {
        let armCount = UInt64(arms.count) + extraConstantArms
        if arms.contains(where: { $0 == .notEnumerable || $0.drawsAmongSeveralPoints }) {
            // A single-arm pick is walked into rather than modeled as a pick, so its arm answers for it.
            return armCount == 1 ? arms[0] : .notEnumerable
        }
        guard arms.allSatisfy({ $0 == .constant || $0 == .enumerable(points: 1) }) else {
            return .unspecified
        }
        guard armCount > 1 else {
            return .constant
        }
        return armCount <= enumerableParameterLimit ? .enumerable(points: armCount) : .notEnumerable
    }
}

private extension ScreeningExpectation {
    /// A one-point parameter cannot vary, so an arm holding only those is covered by its branch index.
    var drawsAmongSeveralPoints: Bool {
        if case let .enumerable(points) = self {
            return points > 1
        }
        return false
    }
}
