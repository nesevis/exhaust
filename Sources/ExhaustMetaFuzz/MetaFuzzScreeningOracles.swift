//
//  MetaFuzzScreeningOracles.swift
//  ExhaustMetaFuzz
//
//  The oracle roster for the screening campaign. The pipeline roster asks whether interpreters agree; this one asks whether screening tells the truth about a domain, because an exhaustive verdict ends a run before random sampling and a wrong one is a silent false pass.
//

import ExhaustCore

// MARK: - Violations

/// Screening reported an exhaustive pass, and random sampling then produced a value none of its rows had shown the property.
public struct ExhaustiveVerdictSoundnessViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Screening's classification of a recipe disagrees with what the recipe grammar makes certain: an enumerable recipe was denied the verdict or sized wrongly, or a recipe with a choice outside the parameter model was offered it.
public struct EnumerabilityClassificationViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Two screening runs of one generator under one budget disagreed on whether the domain was enumerated.
public struct ExhaustiveVerdictStabilityViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

// MARK: - Check

public extension MetaFuzz {
    /// What screening concluded for one case, so a caller can tell a sweep that reached the verdict from one that never did.
    enum ScreeningOutcome: Sendable {
        /// Analysis found no parameters, or generation threw before a verdict.
        case notApplicable
        /// Rows ran and random sampling would follow.
        case partial
        /// Screening claimed the rows were the whole domain, and the claim held.
        case exhaustive
    }

    /// Screening budgets the campaign sweeps, chosen per case. The verdict is gated on the budget, so a fixed one would leave the gate's other side unexamined.
    package static let screeningBudgets: [UInt64] = [16, 64, 256, 2000]

    /// Random samples drawn at each size when checking an exhaustive verdict.
    package static let soundnessSamplesPerSize: UInt64 = 40

    /// Runs the screening oracle roster against one fuzz case, throwing the first violation.
    ///
    /// A throw from generation itself is a vacuous pass, as in ``check(_:)``.
    @discardableResult
    static func checkScreening(_ fuzzCase: MetaFuzzCase) throws -> ScreeningOutcome {
        let generator = buildOracleGenerator(from: fuzzCase.recipe)
        let budget = screeningBudgets[Int(fuzzCase.perturbationSeed % UInt64(screeningBudgets.count))]

        try checkClassification(generator, budget: budget, fuzzCase)

        var rowOutputs: [Any] = []
        let result = ScreeningRunner.run(
            generator,
            screeningBudget: budget,
            coveringSeed: fuzzCase.valueSeed,
            property: { output in
                rowOutputs.append(output)
                return true
            }
        )
        try checkStability(generator, budget: budget, first: result, fuzzCase)

        switch result {
            case .exhaustive:
                try checkSoundness(generator, rowOutputs: rowOutputs, budget: budget, fuzzCase)
                return .exhaustive
            case .partial, .failure:
                return .partial
            case .notApplicable:
                return .notApplicable
        }
    }
}

// MARK: - Individual Oracles

extension MetaFuzz {
    /// Classification: where the recipe grammar settles enumerability, the screening plan must agree in both directions and on the domain's size.
    private static func checkClassification(
        _ generator: AnyGenerator,
        budget: UInt64,
        _ fuzzCase: MetaFuzzCase
    ) throws {
        let expectation = fuzzCase.recipe.screeningExpectation
        let plan = ScreeningRunner.plan(generator, screeningBudget: budget)
        switch expectation {
            case .unspecified:
                return

            case .constant:
                guard plan == nil else {
                    throw EnumerabilityClassificationViolation(
                        "screening found \(plan!.parameterCount) parameter(s) in a recipe that draws nothing: \(fuzzCase.recipe)"
                    )
                }

            case .notEnumerable:
                guard plan?.isExhaustiveCandidate != true else {
                    throw EnumerabilityClassificationViolation(
                        "screening offered the exhaustive verdict (total space \(plan!.totalSpace), budget \(budget)) to a recipe with a choice outside the parameter model: \(fuzzCase.recipe)"
                    )
                }

            case let .enumerable(points):
                guard let plan else {
                    throw EnumerabilityClassificationViolation(
                        "screening found no parameters in an enumerable recipe of \(points) points: \(fuzzCase.recipe)"
                    )
                }
                guard plan.totalSpace == points else {
                    throw EnumerabilityClassificationViolation(
                        "screening sized an enumerable recipe at \(plan.totalSpace) points, expected \(points): \(fuzzCase.recipe)"
                    )
                }
                guard plan.isExhaustiveCandidate == (points <= budget) else {
                    throw EnumerabilityClassificationViolation(
                        "exhaustive candidacy is \(plan.isExhaustiveCandidate) for \(points) points under budget \(budget): \(fuzzCase.recipe)"
                    )
                }
        }
    }

    /// Stability: the verdict describes the generator and the budget, so a different covering seed must not change it.
    private static func checkStability(
        _ generator: AnyGenerator,
        budget: UInt64,
        first: ScreeningRunner.Result<Any>,
        _ fuzzCase: MetaFuzzCase
    ) throws {
        let second = ScreeningRunner.run(
            generator,
            screeningBudget: budget,
            coveringSeed: fuzzCase.perturbationSeed,
            property: { _ in true }
        )
        guard first.isExhaustive == second.isExhaustive else {
            throw ExhaustiveVerdictStabilityViolation(
                "covering seeds \(fuzzCase.valueSeed) and \(fuzzCase.perturbationSeed) disagree on the exhaustive verdict under budget \(budget): \(fuzzCase.recipe)"
            )
        }
    }

    /// Soundness: the verdict's definition. Every value the generator can produce was shown to the property, so no random sample at any size may fall outside the rows.
    private static func checkSoundness(
        _ generator: AnyGenerator,
        rowOutputs: [Any],
        budget: UInt64,
        _ fuzzCase: MetaFuzzCase
    ) throws {
        for size in [UInt64(1), 50, 100] {
            var samples = ValueInterpreter(
                generator,
                seed: fuzzCase.valueSeed &+ size,
                maxRuns: soundnessSamplesPerSize,
                sizeOverride: size
            )
            while true {
                let sample: Any?
                do {
                    sample = try samples.next()
                } catch {
                    break
                }
                guard let sample else {
                    break
                }
                guard rowOutputs.contains(where: { anyEquals($0, sample) }) else {
                    throw ExhaustiveVerdictSoundnessViolation(
                        "size \(size) sample \(sample) is outside the \(rowOutputs.count) rows of an exhaustive verdict under budget \(budget): \(fuzzCase.recipe)"
                    )
                }
            }
        }
    }
}

private extension ScreeningRunner.Result {
    var isExhaustive: Bool {
        if case .exhaustive = self {
            return true
        }
        return false
    }
}
