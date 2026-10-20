//
//  StagedJointEncoder.swift
//  Exhaust
//

// MARK: - Staged Joint Encoder

/// Searches stalled numeric leaves jointly: pairs, three-way groups, and four-way groups, flipping the signs of each selected group before sampling while each preceding stage stalls.
///
/// The encoder's reduction covers a whole checkpoint, as a chain of stages that follow one rule. A stage searches its arity's candidates; a stage that accepts ends the chain, because every group's addresses and domain samples belong to the checkpoint. A stage that exhausts widens the search to one more leaf per group when probes and group calculations remain and a wider group is cheap enough to search: its cheapest sampled grid fits that arity's work limit. All stages share ``ReductionTuning/stagedJointProbeBudget``, and a stage after which the search can widen reserves half of what remains for the wider stage.
enum StagedJointEncoder: ReductionEncoder {
    /// One checkpoint: the pairs to search, the pairs searched only by their sign flip, and the candidate pool for wider groups, all discovered against the same graph.
    struct Scope: Equatable {
        let pairs: [NumericPairQuery.Pair]
        let signFlipPairs: [NumericPairQuery.Pair]
        let candidatePool: [StagedJointQuery.Entry]
    }

    static let maximumArity = 4

    static let name: EncoderName = .stagedJointSearch
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    static func reduce(_ scope: Scope, input: EncoderInput) -> Reduction {
        stage(
            arity: 2,
            candidates: .pairs(scope.pairs, signFlipPairs: scope.signFlipPairs),
            candidatePool: scope.candidatePool,
            remaining: input.tuning.stagedJointProbeBudget,
            calculationsRemaining: input.tuning.numericJointGroupCalculationLimit,
            input: input
        )
    }

    /// Probes a stage of `arity` may spend out of `remaining`: half when the search can widen after it, so the wider stage keeps a share, otherwise all of it. A single remaining probe goes to this stage, and an exhausted budget gives it none.
    static func stageBudget(
        arity: Int,
        candidatePool: [StagedJointQuery.Entry],
        remaining: Int,
        calculationsRemaining: Int,
        tuning: ReductionTuning
    ) -> Int {
        guard remaining > 1 else {
            return remaining
        }
        let reservesProbesForWiderSearch = calculationsRemaining > 0 && canWidenSearch(after: arity, candidatePool: candidatePool, tuning: tuning)
        return reservesProbesForWiderSearch ? remaining / 2 : remaining
    }

    // MARK: - Helpers

    private enum Candidates {
        case pairs([NumericPairQuery.Pair], signFlipPairs: [NumericPairQuery.Pair])
        case groups([NumericJointQuery.Group])
    }

    /// Searches one arity, then widens to the next while the stage stalls and the search can widen.
    private static func stage(
        arity: Int,
        candidates: Candidates,
        candidatePool: [StagedJointQuery.Entry],
        remaining: Int,
        calculationsRemaining: Int,
        input: EncoderInput
    ) -> Reduction {
        let budget = stageBudget(
            arity: arity,
            candidatePool: candidatePool,
            remaining: remaining,
            calculationsRemaining: calculationsRemaining,
            tuning: input.tuning
        )
        let search = switch candidates {
            case let .pairs(pairs, signFlipPairs):
                StagedJointSearch(
                    pairs: pairs,
                    signFlipPairs: signFlipPairs,
                    base: input.baseSequence,
                    probeBudget: budget
                )
            case let .groups(groups):
                StagedJointSearch(groups: groups, base: input.baseSequence, probeBudget: budget)
        }
        return .search(search, configuration: .standard) { outcome in
            let nextArity = arity + 1
            let remaining = remaining - outcome.counts.emitted
            guard outcome.anyAccepted == false,
                  remaining > 0,
                  calculationsRemaining > 0,
                  canWidenSearch(after: arity, candidatePool: candidatePool, tuning: input.tuning)
            else {
                return .pure(.finished)
            }
            let found = StagedJointQuery.groups(
                candidatePool: candidatePool,
                graph: input.graph,
                arity: nextArity,
                workLimit: input.tuning.jointWorkLimit(arity: nextArity),
                calculationLimit: calculationsRemaining,
                scopeLimit: input.tuning.numericJointScopeLimit
            )
            guard found.groups.isEmpty == false else {
                return .pure(.finished)
            }
            return stage(
                arity: nextArity,
                candidates: .groups(found.groups),
                candidatePool: candidatePool,
                remaining: remaining,
                calculationsRemaining: calculationsRemaining - found.calculations,
                input: input
            )
        }
    }

    /// Whether a stage of one more leaf per group can follow a stage of `arity`: the four-way stage is the last, and a wider stage needs a group whose cheapest sampled grid fits that arity's work limit.
    private static func canWidenSearch(after arity: Int, candidatePool: [StagedJointQuery.Entry], tuning: ReductionTuning) -> Bool {
        arity < maximumArity && StagedJointQuery.canWiden(
            to: arity + 1,
            candidatePool: candidatePool,
            workLimit: tuning.jointWorkLimit(arity: arity + 1)
        )
    }
}

// MARK: - Dispatch Requirements

extension StagedJointEncoder {
    static func gate(_ _: Scope) -> DispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: Scope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: Scope, in _: ChoiceGraph) -> Bool {
        true
    }
}
