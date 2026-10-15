//
//  ScopedReductionTuning.swift
//  Exhaust
//

// MARK: - Scoped Reduction Tuning

/// Every budget the scoped reducer's encoders and searches spend, in one place so experiments can vary them without touching search code.
///
/// The runner owns one value and hands it to every encoder it builds.
package struct ScopedReductionTuning: Sendable {
    /// Upstream proposals a bound value scope may build before the gate decays its budget.
    public var boundValueBaseBudget: Int

    /// Maximum probes a bound value scope may emit on a bind fingerprint's first dispatch of the run. Zero means uncapped.
    public var composedFirstDispatchProbeCap: Int

    /// Probes each controller candidate's downstream search emits per turn in a nested bind chain before the next candidate gets a turn. Applies only under ``ScopedChoiceScheduling/turnBased``; diagonal scheduling selects again after every candidate.
    public var probesPerControllerCandidateTurn: Int

    /// Downstream builds one dispatch of a nested bind chain of three or fewer searches may spend across all its searches, counting failed builds and builds whose search emits nothing. Each build materializes the generator, and nesting multiplies them, so the chain root owns one pool for the whole chain.
    public var nestedChainBaseBuildPool: Int

    /// Upper bound on ``nestedChainBuildPool(chainLength:)``, whatever the chain's length.
    public var nestedChainMaxBuildPool: Int

    /// Builds the chain root may spend per start. Deeper searches get less; see ``nestedChainBuildsPerStart(depth:)``.
    public var nestedChainRootBuildsPerStart: Int

    /// Lifts a bound exchange scope may keep, counting only lifts that preserve the proposal's expected sink value.
    public var keptExchangeLiftBudget: Int

    /// Descendant transplants a bind pivot tries beyond the plain pivot, smallest first. Each costs one lift before any probe is emitted. ``MinimizationQuery`` prices bind pivot scopes with ``MinimizationQuery/bindPivotMaxTransplants``, so changing this changes how many seeds are built but not the scope's priority.
    public var maxPivotTransplants: Int

    /// Largest gap below a converged bound that value search scans linearly, for properties that are not monotone in the leaf's value.
    public var valueLinearScanThreshold: UInt64

    /// Interpolation divisor batch bisection starts with for a group of leaves, and returns to after each acceptance.
    public var valueBisectionInitialDivisor: UInt64

    /// Divisor at which batch bisection stops halving and splits the group instead.
    public var valueBisectionBinaryThreshold: UInt64

    /// Interval size below which per-leaf interpolation search becomes binary search.
    public var interpolationBinaryThreshold: UInt64

    /// Interpolation divisor per-leaf search starts with and returns to after each acceptance.
    public var interpolationInitialDivisor: UInt64

    /// Replay passes redistribution makes over its accepted pairs.
    public var redistributionMaxPasses: Int

    /// Pairs one redistribution search keeps from its scope, best ranked first.
    public var redistributionMaxPairs: Int

    /// Suffix windows lockstep plans per group of same-tag leaves, each dropping one more leading leaf. Caps plan construction on large groups.
    public var lockstepMaxSuffixWindows: Int

    /// Maximum combinations covering enumerates exhaustively.
    public var coveringExhaustiveThreshold: UInt64

    /// Maximum rows covering emits in its pairwise and range-end regimes.
    public var coveringBudget: Int

    /// Maximum value positions one covering search varies. Positions past it, in collection order, stay fixed at their base values. Pairwise covering builds one slice per parameter pair, so its setup grows quadratically with the parameter count, and the deadline is only checked between probes.
    public var maxCoveredPositions: Int

    /// Probes one staged joint checkpoint may spend, shared by its sequential two-, three-, and four-way stages. Zero disables staged joint search.
    public var stagedJointProbeBudget: Int

    /// Maximum estimated candidate combinations retained for three-way search after two-way search stalls. Work sums each group's sampled grid, including compensating increases, plus every ratio-preserving proposal outside that grid. Ranked groups are retained only while their total fits; residual magnitude affects priority rather than eligibility. Zero disables this stage and four-way escalation.
    public var threeWayNumericWorkLimit: Int

    /// Maximum estimated candidate combinations retained for four-way search after three-way search stalls, estimated as for ``threeWayNumericWorkLimit``. Zero disables four-way escalation.
    public var fourWayNumericWorkLimit: Int

    /// Higher-order groups scored across both escalation stages of one checkpoint. Discovery stops at this count before retaining the best groups, so discarded groups cannot cause unbounded preparation.
    public var numericJointGroupCalculationLimit: Int

    /// Ranked groups retained in each higher-order stage.
    public var numericJointScopeLimit: Int

    /// Numeric leaves pair discovery considers, in position order after non-numeric leaves are filtered out.
    public var numericPairMaximumLeaves: Int

    /// Pairs one staged joint checkpoint searches.
    public var numericPairMaximumPairs: Int

    /// Leaves the candidate pool for three-way and four-way groups keeps, stalled and nearest to target first.
    public var numericJointMaximumLeaves: Int

    /// Perturbations a relax round may decode before it gives up without exploiting one. Zero disables relax rounds.
    public var relaxMaterializationBudget: Int

    /// Improving pivot probes per post-cycle phase. Separate from ``relaxMaterializationBudget``, so spending it never changes which perturbations a relax round reaches. Zero disables the phase.
    public var relaxImprovingProbeBudget: Int

    /// Consecutive migration passes that reject every probe, after which migration is skipped for the rest of the run. An acceptance resets the count. Zero never demotes.
    public var migrationDemotionThreshold: Int

    package init(
        boundValueBaseBudget: Int = 15,
        composedFirstDispatchProbeCap: Int = 16,
        probesPerControllerCandidateTurn: Int = 2,
        nestedChainBaseBuildPool: Int = 128,
        nestedChainMaxBuildPool: Int = 1024,
        nestedChainRootBuildsPerStart: Int = 64,
        keptExchangeLiftBudget: Int = 8,
        maxPivotTransplants: Int = 4,
        valueLinearScanThreshold: UInt64 = 64,
        valueBisectionInitialDivisor: UInt64 = 16,
        valueBisectionBinaryThreshold: UInt64 = 4,
        interpolationBinaryThreshold: UInt64 = 1024,
        interpolationInitialDivisor: UInt64 = 16,
        redistributionMaxPasses: Int = 16,
        redistributionMaxPairs: Int = 30,
        lockstepMaxSuffixWindows: Int = 50,
        coveringExhaustiveThreshold: UInt64 = 32,
        coveringBudget: Int = 64,
        maxCoveredPositions: Int = 64,
        stagedJointProbeBudget: Int = 512,
        threeWayNumericWorkLimit: Int = 4096,
        fourWayNumericWorkLimit: Int = 1024,
        numericJointGroupCalculationLimit: Int = 512,
        numericJointScopeLimit: Int = 30,
        numericPairMaximumLeaves: Int = 256,
        numericPairMaximumPairs: Int = 30,
        numericJointMaximumLeaves: Int = 16,
        relaxMaterializationBudget: Int = 10,
        relaxImprovingProbeBudget: Int = 2,
        migrationDemotionThreshold: Int = 3
    ) {
        self.boundValueBaseBudget = boundValueBaseBudget
        self.composedFirstDispatchProbeCap = composedFirstDispatchProbeCap
        self.probesPerControllerCandidateTurn = probesPerControllerCandidateTurn
        self.nestedChainBaseBuildPool = nestedChainBaseBuildPool
        self.nestedChainMaxBuildPool = nestedChainMaxBuildPool
        self.nestedChainRootBuildsPerStart = nestedChainRootBuildsPerStart
        self.keptExchangeLiftBudget = keptExchangeLiftBudget
        self.maxPivotTransplants = maxPivotTransplants
        self.valueLinearScanThreshold = valueLinearScanThreshold
        self.valueBisectionInitialDivisor = valueBisectionInitialDivisor
        self.valueBisectionBinaryThreshold = valueBisectionBinaryThreshold
        self.interpolationBinaryThreshold = interpolationBinaryThreshold
        self.interpolationInitialDivisor = interpolationInitialDivisor
        self.redistributionMaxPasses = redistributionMaxPasses
        self.redistributionMaxPairs = redistributionMaxPairs
        self.lockstepMaxSuffixWindows = lockstepMaxSuffixWindows
        self.coveringExhaustiveThreshold = coveringExhaustiveThreshold
        self.coveringBudget = coveringBudget
        self.maxCoveredPositions = maxCoveredPositions
        self.stagedJointProbeBudget = stagedJointProbeBudget
        self.threeWayNumericWorkLimit = threeWayNumericWorkLimit
        self.fourWayNumericWorkLimit = fourWayNumericWorkLimit
        self.numericJointGroupCalculationLimit = numericJointGroupCalculationLimit
        self.numericJointScopeLimit = numericJointScopeLimit
        self.numericPairMaximumLeaves = numericPairMaximumLeaves
        self.numericPairMaximumPairs = numericPairMaximumPairs
        self.numericJointMaximumLeaves = numericJointMaximumLeaves
        self.relaxMaterializationBudget = relaxMaterializationBudget
        self.relaxImprovingProbeBudget = relaxImprovingProbeBudget
        self.migrationDemotionThreshold = migrationDemotionThreshold
    }

    /// Estimated work a three-way or four-way staged joint stage may retain.
    ///
    /// - Precondition: `arity` is three or four; no other arity has a higher-order stage.
    func jointWorkLimit(arity: Int) -> Int {
        switch arity {
            case 3:
                threeWayNumericWorkLimit
            case 4:
                fourWayNumericWorkLimit
            default:
                preconditionFailure("Staged joint search has no stage of arity \(arity)")
        }
    }

    /// Builds a chain of `chainLength` searches may spend: ``nestedChainBaseBuildPool`` for three or fewer searches, quadrupled for each search beyond that, and at most ``nestedChainMaxBuildPool``. A fixed pool spread over more searches leaves each controller fewer candidates.
    func nestedChainBuildPool(chainLength: Int) -> Int {
        var pool = nestedChainBaseBuildPool
        var length = 3
        while length < chainLength, pool < nestedChainMaxBuildPool {
            pool *= 4
            length += 1
        }
        return min(pool, nestedChainMaxBuildPool)
    }

    /// Builds a chain search at `depth` may spend per start: ``nestedChainRootBuildsPerStart`` at the root, three quarters of the level above at each deeper level, and at least one.
    func nestedChainBuildsPerStart(depth: Int) -> Int {
        var builds = nestedChainRootBuildsPerStart
        var level = 0
        while level < depth {
            builds = builds * 3 / 4
            level += 1
        }
        return max(builds, 1)
    }
}
