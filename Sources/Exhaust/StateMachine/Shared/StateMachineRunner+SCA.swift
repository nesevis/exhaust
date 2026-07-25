// SCA (Sequence Covering Array) screening phase for spec testing.
import ExhaustCore
import Foundation

// MARK: - Shared SCA Row Loop

extension __ExhaustRuntime {
    /// Reports the raw outcome of the SCA row loop before caller-specific failure handling.
    ///
    /// Each caller handles the ``failure`` case differently. The sequential path prunes skipped commands and reduces directly, while the concurrent source wraps the value in a ``StateMachineCandidate`` for the machine to reduce.
    enum SCARowLoopResult<Value> {
        /// A counterexample was found at the given screening iteration.
        case failure(value: Value, tree: ChoiceTree, screeningInvocations: Int)
        /// The covering array was exhausted without finding a failure.
        case completed(screeningInvocations: Int)
        /// SCA was not applicable (generator structure or domain too small).
        case skipped
    }

    /// Core SCA screening row loop shared by the sequential and concurrent spec runners.
    ///
    /// Builds covering arrays at multiple sequence lengths to cover both short and long command sequences. Budget is split across length tiers: 50% at `min(5, commandLimit)`, 25% at `max(5, commandLimit / 2)`, 25% at `commandLimit`, with duplicate lengths collapsed and their budgets merged. Tiers run shortest-first so minimal counterexamples are found early.
    ///
    /// Returns ``SCARowLoopResult/skipped`` when domain construction fails or the domain is too small for pairwise coverage. Returns ``SCARowLoopResult/failure(value:tree:screeningInvocations:)`` with the raw (unreduced) counterexample so callers can apply their own reduction logic. The `logEventPrefix` parameterizes log event names: `"statemachine_screening"` for a fresh run, `"statemachine_screening_replay"` for row replay.
    static func runSCAScreeningRowLoop<Row, Value>(
        sequenceGen: Generator<Row>,
        commandGen: Generator<some Any>,
        commandLimit: Int,
        screeningBudget: UInt64,
        skipToRow: Int?,
        logEventPrefix: String,
        concurrencyLevel: Int? = nil,
        sequenceGenForLength: ((ClosedRange<UInt64>) -> Generator<Row>)? = nil,
        leadingFactors: ScreeningLeadingFactors? = nil,
        combine: (ChoiceTree?, Row, ChoiceTree) -> (value: Value, tree: ChoiceTree)?,
        property: @escaping @Sendable (Value) -> Bool
    ) -> SCARowLoopResult<Value> {
        guard let pickChoices = extractPickChoices(from: commandGen) else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "\(logEventPrefix)_skipped",
                "Command generator is not a top-level pick. SCA not applicable."
            )
            return .skipped
        }

        guard commandLimit >= 2 else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "\(logEventPrefix)_skipped",
                metadata: [
                    "sequence_length": "\(commandLimit)",
                    "reason": "sequence length must be >= 2 for SCA",
                ]
            )
            return .skipped
        }

        let tiers = buildScreeningTiers(commandLimit: commandLimit, totalBudget: screeningBudget)

        var totalIterations = 0

        for tier in tiers {
            let domain: SCADomain
            if let concurrencyLevel {
                domain = SCADomain.buildForStateMachine(
                    sequenceLength: tier.length,
                    pickChoices: pickChoices,
                    concurrencyLevel: concurrencyLevel,
                    strengthCap: 2
                )
            } else {
                guard let built = SCADomain.build(
                    sequenceLength: tier.length,
                    pickChoices: pickChoices,
                    screeningBudget: tier.budget,
                    strengthCap: 2
                ) else {
                    continue
                }
                domain = built
            }

            let rowDomainSizes = domain.profile.domainSizes
            guard rowDomainSizes.count >= 2 else {
                continue
            }

            // The leading block's factors join the same covering array, so strength-2 coverage pairs every leading
            // value with every per-position command value. Its slice of each row is replayed through its own
            // generator by `combine`; it is never folded into the row's fallback tree.
            let leadingDomainSizes = leadingFactors?.domainSizes ?? []
            let generator = BalancedCoveringArrayGenerator(domainSizes: leadingDomainSizes + rowDomainSizes)
            var tierIterations: UInt64 = 0
            var tierAttempts: UInt64 = 0
            // A replay must land on the exact row discovery found. The global row index depends on how many rows each tier contributes, and the fractional `tier.budget` split makes that budget-dependent — so a replay under a smaller budget would cut a tier short and shift the target row into a different combination. A replay only needs to *reach* `skipToRow` (earlier rows are skipped without running the property), so cap each tier at `skipToRow + 1` instead: every tier then runs to its covering-array completion up to the target, matching the discovery run's row numbering regardless of the replay budget.
            let tierRowCap = skipToRow.map { UInt64($0) + 1 } ?? tier.budget
            let maxAttempts = tierRowCap * 10

            let tierLengthRange = UInt64(tier.length) ... UInt64(tier.length)
            let tierGen = sequenceGenForLength?(tierLengthRange) ?? sequenceGen

            while tierIterations < tierRowCap, tierAttempts < maxAttempts, let combinedRow = generator.next() {
                tierAttempts += 1
                let leadingRow = CoveringArrayRow(values: Array(combinedRow.values.prefix(leadingDomainSizes.count)))
                let rowValues = CoveringArrayRow(values: Array(combinedRow.values.dropFirst(leadingDomainSizes.count)))
                guard let tree = domain.buildTree(row: rowValues, sequenceLengthRange: tierLengthRange) else {
                    continue
                }
                let leadingTree = leadingFactors.flatMap { $0.buildTree(leadingRow) }
                if leadingFactors != nil, leadingTree == nil {
                    continue
                }

                // The row tree describes the row generator alone, so guided materialization sees a fallback built for
                // exactly the generator it is materializing. Any leading block is materialized separately in `combine`.
                let mode = Materializer.Mode.guided(
                    seed: UInt64(totalIterations),
                    fallbackTree: tree
                )
                guard case let .success(rowValue, freshTree, _) = Materializer.materialize(
                    tierGen, prefix: ChoiceSequence(), mode: mode
                ) else {
                    continue
                }
                guard let (value, candidateTree) = combine(leadingTree, rowValue, freshTree) else {
                    continue
                }

                tierIterations += 1
                totalIterations += 1
                if let skipToRow, totalIterations - 1 < skipToRow {
                    continue
                }
                if property(value) == false {
                    return .failure(value: value, tree: candidateTree, screeningInvocations: totalIterations)
                }
                if skipToRow != nil {
                    return .completed(screeningInvocations: totalIterations)
                }
            }
        }

        ExhaustLog.notice(
            category: .propertyTest,
            event: logEventPrefix,
            metadata: [
                "command_types": "\(pickChoices.count)",
                "iterations": "\(totalIterations)",
                "command_limit": "\(commandLimit)",
                "tiers": "\(tiers.count)",
                "strength": "2",
            ]
        )

        return .completed(screeningInvocations: totalIterations)
    }

    /// Computes screening tiers with deduplicated lengths and proportional budget allocation.
    ///
    /// Raw tiers: 50% at `min(5, commandLimit)`, 25% at `max(5, commandLimit / 2)`, 25% at `commandLimit`. Tiers with duplicate lengths are collapsed and their budgets merged. The minimum sequence length for any tier is 2 (pairwise coverage requires at least 2 parameters).
    private static func buildScreeningTiers(
        commandLimit: Int,
        totalBudget: UInt64
    ) -> [(length: Int, budget: UInt64)] {
        let shortLength = min(5, commandLimit)
        let rawTiers: [(length: Int, fraction: UInt64, denominator: UInt64)] = [
            (length: shortLength, fraction: 1, denominator: 2),
            (length: max(shortLength, commandLimit / 2), fraction: 1, denominator: 4),
            (length: commandLimit, fraction: 1, denominator: 4),
        ]
        let minLength = 2

        var merged: [(length: Int, fraction: UInt64, denominator: UInt64)] = []
        for raw in rawTiers {
            guard raw.length >= minLength else {
                continue
            }
            if let existingIndex = merged.firstIndex(where: { $0.length == raw.length }) {
                let existing = merged[existingIndex]
                let combinedNumerator = existing.fraction * raw.denominator + raw.fraction * existing.denominator
                let combinedDenominator = existing.denominator * raw.denominator
                merged[existingIndex] = (length: raw.length, fraction: combinedNumerator, denominator: combinedDenominator)
            } else {
                merged.append(raw)
            }
        }

        merged.sort { $0.length < $1.length }

        var result: [(length: Int, budget: UInt64)] = []
        var allocated: UInt64 = 0
        for (index, tier) in merged.enumerated() {
            let budget: UInt64
            if index == merged.count - 1 {
                budget = totalBudget - allocated
            } else {
                budget = totalBudget * tier.fraction / tier.denominator
            }
            guard budget > 0 else {
                continue
            }
            result.append((length: tier.length, budget: budget))
            allocated += budget
        }

        return result
    }
}

// MARK: - Pick Analysis

extension __ExhaustRuntime {
    /// Extracts pick choices from a command generator when the generator is a top-level ``Gen.pick``.
    static func extractPickChoices(
        from gen: Generator<some Any>
    ) -> ContiguousArray<ReflectiveOperation.PickTuple>? {
        guard case let .impure(operation, _) = gen,
              case let .pick(choices, _) = operation
        else {
            return nil
        }
        return choices
    }

    /// Estimates a default command limit from the command generator's structure and the screening budget.
    ///
    /// Pre-analyzes pick branches to determine the per-position domain size, then computes the sequence length at which SCA rows (at t=2) would exhaust the budget. The result is the larger of this budget ceiling and an exploration floor based on the number of command types, ensuring sequences are long enough for each command to appear several times.
    static func estimateCommandLimit(
        commandGen: Generator<some Any>,
        screeningBudget: UInt64
    ) -> Int {
        guard let pickChoices = extractPickChoices(from: commandGen) else {
            return 10
        }

        let branchCount = pickChoices.count

        // Pre-analyze branch argument domains to estimate the per-position domain size.
        // Use sequenceLength=10 as initial estimate for threshold computation; the threshold is under a sqrt so it is not very sensitive to this value.
        let threshold = SequenceCoveringArray.computeThreshold(
            budget: screeningBudget,
            sequenceLength: 10,
            branchCount: branchCount
        )
        let branchProfiles = SequenceCoveringArray.analyzeBranches(
            pickChoices,
            threshold: threshold,
            screeningBudget: screeningBudget
        )
        var domainSize: UInt64 = 0
        for profile in branchProfiles {
            let contribution: UInt64 = switch profile {
                case .parameterFree, .unanalyzable:
                    1
                case let .analyzed(params):
                    params.reduce(UInt64(1)) { partialProduct, param in
                        let (result, overflow) = partialProduct.multipliedReportingOverflow(by: param.domainSize)
                        return overflow ? .max : result
                    }
            }
            let (sum, overflow) = domainSize.addingReportingOverflow(contribution)
            domainSize = overflow ? .max : sum
        }

        // Budget ceiling: at t=2, covering array rows ≈ d² × ln(L).
        // Solving for L: L = e^(B / d²).
        // For small domains this is huge (budget is not the bottleneck); for large domains it can be < 2.
        let domainSizeEstimate = Double(min(domainSize, UInt64(Int.max)))
        let domainSizeSquared = max(domainSizeEstimate * domainSizeEstimate, 1.0)
        let ratio = Double(screeningBudget) / domainSizeSquared
        let budgetCeiling = ratio > 1 ? Int(min(exp(ratio), 100)) : 2

        // Exploration floor: enough for each command type to appear several times, ensuring the random phase can reach meaningful state depths.
        let explorationFloor = max(branchCount * 3, 6)

        let limit = max(explorationFloor, budgetCeiling)

        ExhaustLog.notice(
            category: .propertyTest,
            event: "estimated_command_limit",
            metadata: [
                "command_limit": "\(limit)",
                "command_types": "\(branchCount)",
                "domain_size": "\(domainSize)",
                "budget_ceiling": "\(budgetCeiling)",
                "exploration_floor": "\(explorationFloor)",
            ]
        )

        return limit
    }
}
