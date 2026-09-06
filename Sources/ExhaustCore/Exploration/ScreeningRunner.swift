// Encapsulates the screening phase of a property test.
//
// Analyzes the generator, then pulls rows from BalancedCoveringArrayGenerator one at a time, testing each against the property. Stops on first failure or budget.

/// Runs the screening phase of a property test, exhausting the generator's enumerable or large domain before the random phase.
package enum ScreeningRunner {
    /// Headroom the domain model gets over the per-run row budget.
    ///
    /// Both model gates below (the composite threshold passed to analysis and the pair-product downgrade) compare against the row budget scaled by this factor rather than the raw budget. Per-run covering-seed rotation starts each run at a different row window, so a model larger than one run's rows still completes its pair coverage across successive runs. Every parameter still sweeps its full value catalog within roughly one run. Without the headroom, two-element composite slots for the character and float catalogs exceed the raw standard budget and go opaque, so their pair space is never screened.
    package static let modelOverprovisionFactor: UInt64 = 4

    /// The domain-model budget for a per-run row budget: the budget scaled by ``modelOverprovisionFactor``, saturating on overflow.
    package static func modelBudget(for screeningBudget: UInt64) -> UInt64 {
        let (product, overflow) = screeningBudget.multipliedReportingOverflow(by: modelOverprovisionFactor)
        return overflow ? .max : product
    }

    /// Separates covering-row progress from the property calls that those rows produce.
    package struct Summary: Equatable, Sendable {
        /// Number of covering rows considered as candidate opportunities.
        package var rowAttempts = 0

        /// Property invocations during screening.
        package var propertyInvocations = 0

        /// Number of rows rejected while building or materializing their candidate.
        package var rejectedRows = 0
    }

    /// The outcome of a screening run.
    package enum Result<Output> {
        /// Screening found a counterexample before exhausting the domain.
        case failure(
            value: Output, tree: ChoiceTree,
            rowOrdinal: Int, summary: Summary,
            strength: Int, rows: Int,
            parameters: Int, totalSpace: UInt64, kind: String
        )
        /// The entire enumerable domain was tested without finding a counterexample; the random phase can be skipped.
        case exhaustive(summary: Summary)
        /// Screening completed its budget without a counterexample; proceed to the random phase.
        case partial(
            summary: Summary, strength: Int, rows: Int,
            parameters: Int, totalSpace: UInt64, kind: String
        )
        /// The generator has no analyzable enumerable or large domain; skip screening entirely.
        case notApplicable

        /// Returns the accounting summary carried by an applicable screening result.
        package var summary: Summary {
            switch self {
                case let .failure(_, _, _, summary, _, _, _, _, _),
                     let .exhaustive(summary),
                     let .partial(summary, _, _, _, _, _):
                    summary
                case .notApplicable:
                    Summary()
            }
        }
    }

    /// The analyzed screening domain for one run: the profile that turns rows into trees, and the figures the result reports.
    package struct Plan {
        package let profile: any ScreeningProfile
        package let domainSizes: [UInt64]
        package let parameterCount: Int
        package let totalSpace: UInt64
        /// Rows this run may test, `screeningBudget` clamped to `Int`.
        package let budget: Int
        package let screeningBudget: UInt64
        /// 2 for the pairwise covering array, 1 for the single-parameter sweep.
        package let strength: Int
        package let kind: String
        /// Whether a run that tests every row without a rejection or failure has covered the whole domain.
        package let isExhaustiveCandidate: Bool
    }

    /// Analyzes the generator into a ``Plan``, or nil when it has no analyzable enumerable or large domain.
    package static func plan(_ gen: Generator<some Any>, screeningBudget: UInt64) -> Plan? {
        let modelBudget = Self.modelBudget(for: screeningBudget)
        guard var analysis = ChoiceTreeAnalysis.analyze(gen, compositeThreshold: modelBudget) else {
            return nil
        }

        if case let .large(largeProfile) = analysis {
            let sorted = largeProfile.domainSizes.sorted(by: >)
            let largestPairProduct = sorted.prefix(2).reduce(UInt64(1), *)
            if largestPairProduct > modelBudget,
               let smaller = ChoiceTreeAnalysis.analyze(gen, expandSequencePairs: false, compositeThreshold: modelBudget)
            {
                analysis = smaller
            }
        }

        let profile: any ScreeningProfile
        let kind: String
        let isExhaustiveCandidate: Bool

        switch analysis {
            case let .enumerable(enumerableProfile):
                profile = enumerableProfile
                kind = "enumerable"
                isExhaustiveCandidate = enumerableProfile.totalSpace <= screeningBudget
                    && enumerableProfile.originalTree?.containsBind == false

            case let .large(largeProfile):
                profile = largeProfile
                kind = "large"
                isExhaustiveCandidate = false
        }

        guard profile.parameterCount >= 1 else {
            return nil
        }
        return Plan(
            profile: profile,
            domainSizes: profile.domainSizes,
            parameterCount: profile.parameterCount,
            totalSpace: profile.totalSpace,
            budget: Int(min(screeningBudget, UInt64(Int.max))),
            screeningBudget: screeningBudget,
            strength: profile.parameterCount >= 2 ? 2 : 1,
            kind: kind,
            isExhaustiveCandidate: isExhaustiveCandidate
        )
    }

    /// The covering rows of one run, pulled one at a time: the pairwise stream for two or more parameters, the rotated sweep for one.
    ///
    /// A plain `next()` rather than `IteratorProtocol`, which would put a witness call and Optional wrapping on every row in debug builds. `skipToRow` consumes the rows before the target without yielding them and ends the stream after the target; ``consumed`` is the row count a result reports.
    package struct Rows {
        private let plan: Plan
        private let skipToRow: Int?
        private let nextPairwiseRow: (() -> CoveringArrayRow?)?
        private let rotationStart: UInt64
        private var rowIndex: Int
        private var finished = false

        /// Rows advanced so far: every row yielded plus every row skipped up to a target.
        package var consumed: Int {
            rowIndex
        }

        package init(plan: Plan, coveringSeed: UInt64, skipToRow: Int?) {
            self.plan = plan
            self.skipToRow = skipToRow
            if plan.parameterCount >= 2 {
                // Saturation gates on this run's budget to match the `.exhaustive` result; a screening-row replay must therefore run under the discovery budget, which the budget-dependent domain analysis already requires.
                nextPairwiseRow = SaturatingRowGenerator.rowStream(
                    domainSizes: plan.domainSizes,
                    seed: coveringSeed,
                    saturationBudget: plan.screeningBudget
                )
                rotationStart = 0
                rowIndex = 0
            } else {
                // The covering seed rotates the sweep's start so a domain larger than the budget has no permanently untestable tail: successive runs sweep different windows and collectively reach every value, matching the pairwise path's per-run rotation.
                nextPairwiseRow = nil
                rotationStart = plan.domainSizes[0] > 0 ? coveringSeed % plan.domainSizes[0] : 0
                rowIndex = skipToRow ?? 0
            }
        }

        /// The next row and its index, or nil at the budget, the end of the stream, or after the replay target.
        package mutating func next() -> (index: Int, row: CoveringArrayRow)? {
            guard finished else {
                if let nextPairwiseRow {
                    while rowIndex < plan.budget, let row = nextPairwiseRow() {
                        if let target = skipToRow, rowIndex < target {
                            rowIndex += 1
                            continue
                        }
                        return yield(row)
                    }
                    return nil
                }
                guard rowIndex < plan.budget, UInt64(rowIndex) < plan.domainSizes[0] else {
                    return nil
                }
                let row = CoveringArrayRow(values: [(rotationStart &+ UInt64(rowIndex)) % plan.domainSizes[0]])
                return yield(row)
            }
            return nil
        }

        private mutating func yield(_ row: CoveringArrayRow) -> (index: Int, row: CoveringArrayRow) {
            let index = rowIndex
            if skipToRow == nil {
                rowIndex += 1
            } else {
                finished = true
            }
            return (index, row)
        }
    }

    /// Runs screening and iterates through the covering array, calling `property` for each row.
    ///
    /// - Parameters:
    ///   - skipToRow: When set, skips property evaluation for all rows before this index and only tests the target row. Used for O(1) screening replay.
    ///   - continuePastFailure: When `true`, a failing row is reported through `onExample` and iteration continues instead of returning `.failure`. A run that continued past a failure never reports `.exhaustive`, because that case asserts the domain passed.
    package static func run<Output>(
        _ gen: Generator<Output>,
        screeningBudget: UInt64,
        coveringSeed: UInt64,
        skipToRow: Int? = nil,
        continuePastFailure: Bool = false,
        property: (Output) -> Bool,
        onExample: ((Output, ChoiceTree, Bool) -> Void)? = nil
    ) -> Result<Output> {
        guard let plan = plan(gen, screeningBudget: screeningBudget) else {
            return .notApplicable
        }
        // Erase once for the whole screening loop; materializeRow takes the erased generator to avoid per-row erasure.
        let erasedGen = gen.erase()
        // A passing row's tree is only read by the onExample stats callback; without one, the row is materialized without a tree and a failing row is materialized again for the report.
        let needsTree = onExample != nil

        var rows = Rows(plan: plan, coveringSeed: coveringSeed, skipToRow: skipToRow)
        var summary = Summary()
        var failureObserved = false
        while let (rowIndex, row) = rows.next() {
            summary.rowAttempts += 1
            guard let (value, tree) = materializeRow(erasedGen, row: row, rowIndex: rowIndex, profile: plan.profile, needsTree: needsTree) as (Output, ChoiceTree)? else {
                summary.rejectedRows += 1
                continue
            }
            summary.propertyInvocations += 1
            let passed = property(value)
            var reportedTree = tree
            if needsTree == false, passed == false {
                // The failure path reads the tree, so rebuild it. Same seed and fallback reproduce the first pass deterministically; a divergence cannot happen, and skipping the row is the safe response if it somehow does.
                guard let (_, realTree) = materializeRow(erasedGen, row: row, rowIndex: rowIndex, profile: plan.profile, needsTree: true) as (Output, ChoiceTree)? else {
                    summary.propertyInvocations -= 1
                    summary.rejectedRows += 1
                    continue
                }
                reportedTree = realTree
            }
            onExample?(value, reportedTree, passed)
            if passed == false {
                if continuePastFailure {
                    failureObserved = true
                } else {
                    return .failure(
                        value: value, tree: reportedTree,
                        rowOrdinal: rowIndex + 1, summary: summary,
                        strength: plan.strength, rows: rowIndex + 1,
                        parameters: plan.parameterCount, totalSpace: plan.totalSpace, kind: plan.kind
                    )
                }
            }
        }

        // Only report exhaustive when every point in the domain was tested, not just all t-tuples.
        let domainRows = plan.parameterCount >= 2 ? plan.totalSpace : plan.domainSizes[0]
        if plan.isExhaustiveCandidate,
           skipToRow == nil,
           failureObserved == false,
           summary.rejectedRows == 0,
           UInt64(summary.rowAttempts) >= domainRows
        {
            return .exhaustive(summary: summary)
        }

        return .partial(
            summary: summary, strength: plan.strength, rows: rows.consumed,
            parameters: plan.parameterCount, totalSpace: plan.totalSpace, kind: plan.kind
        )
    }

    // MARK: - Row Materialization

    /// Builds a tree from a covering array row and materializes it, returning the value and its tree, or nil when the row cannot be built or materialized.
    ///
    /// With `needsTree` false the walk skips ``ChoiceTree`` construction and the returned tree is a placeholder; guided materialization is deterministic for a fixed seed and fallback tree, so a second call with `needsTree` true produces the same value with the real tree (the same pattern ``SequenceDecoder`` uses).
    package static func materializeRow<Output>(
        _ erasedGen: AnyGenerator,
        row: CoveringArrayRow,
        rowIndex: Int,
        profile: any ScreeningProfile,
        needsTree: Bool
    ) -> (value: Output, tree: ChoiceTree)? {
        guard let tree = profile.buildTree(from: row) else {
            return nil
        }
        let mode = Materializer.Mode.guided(seed: UInt64(rowIndex), fallbackTree: nil)
        switch Materializer.materializeAny(
            erasedGen, prefix: ChoiceSequence(), mode: mode, fallbackTree: tree,
            skipTree: needsTree == false,
            collectDecodingReport: false
        ) {
            case let .success(anyValue, freshTree, _):
                // swiftlint:disable:next force_cast
                return (anyValue as! Output, freshTree)
            case .rejected, .failed:
                return nil
        }
    }
}
