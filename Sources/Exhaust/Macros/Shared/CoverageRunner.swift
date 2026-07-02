// Encapsulates the coverage phase of a property test.
//
// Analyzes the generator, then pulls rows from BalancedCoveringArrayGenerator one at a time, testing each against the property. Stops on first failure or budget.
import ExhaustCore

/// Runs the coverage phase of a property test, exhausting the generator's enumerable or large domain before the random phase.
package enum CoverageRunner {
    /// The outcome of a coverage run.
    package enum Result<Output> {
        /// Coverage found a counterexample before exhausting the domain.
        case failure(
            value: Output, tree: ChoiceTree,
            iteration: Int, strength: Int, rows: Int,
            parameters: Int, totalSpace: UInt64, kind: String
        )
        /// The entire enumerable domain was tested without finding a counterexample; the random phase can be skipped.
        case exhaustive(iterations: Int)
        /// Coverage completed its budget without a counterexample; proceed to the random phase.
        case partial(
            iterations: Int, strength: Int, rows: Int,
            parameters: Int, totalSpace: UInt64, kind: String
        )
        /// The generator has no analyzable enumerable or large domain; skip coverage entirely.
        case notApplicable
    }

    /// Runs coverage analysis and iterates through the covering array, calling `property` for each row.
    ///
    /// - Parameter skipToRow: When set, skips property evaluation for all rows before this index and only tests the target row. Used for O(1) coverage replay.
    package static func run<Output>(
        _ gen: Generator<Output>,
        coverageBudget: UInt64,
        skipToRow: Int? = nil,
        property: (Output) -> Bool,
        onExample: ((Output, ChoiceTree, Bool) -> Void)? = nil
    ) -> Result<Output> {
        guard var analysis = ChoiceTreeAnalysis.analyze(gen, compositeThreshold: coverageBudget) else {
            return .notApplicable
        }

        if case let .large(largeProfile) = analysis {
            let sorted = largeProfile.domainSizes.sorted(by: >)
            let largestPairProduct = sorted.prefix(2).reduce(UInt64(1), *)
            if largestPairProduct > coverageBudget,
               let smaller = ChoiceTreeAnalysis.analyze(gen, expandSequencePairs: false, compositeThreshold: coverageBudget)
            {
                analysis = smaller
            }
        }

        let profile: any CoverageProfile
        let kind: String
        let isExhaustiveCandidate: Bool

        switch analysis {
            case let .enumerable(enumerableProfile):
                profile = enumerableProfile
                kind = "enumerable"
                isExhaustiveCandidate = enumerableProfile.totalSpace <= coverageBudget
                    && enumerableProfile.originalTree?.containsBind == false

            case let .large(largeProfile):
                profile = largeProfile
                kind = "large"
                isExhaustiveCandidate = false
        }

        let domainSizes = profile.domainSizes
        let paramCount = profile.parameterCount
        let totalSpace = profile.totalSpace
        let budget = Int(min(coverageBudget, UInt64(Int.max)))

        guard paramCount >= 1 else { return .notApplicable }

        // Erase once for the whole coverage loop; testRow calls materializeAny directly to avoid per-row erasure.
        let erasedGen = gen.erase()
        // A passing row's tree is only read by the onExample stats callback; without one, testRow skips tree construction.
        let needsTree = onExample != nil

        // Pull-based pairwise coverage for 2+ parameters.
        if paramCount >= 2 {
            let generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)
            var iterations = 0
            var rowIndex = 0
            while rowIndex < budget, let row = generator.next() {
                if let target = skipToRow, rowIndex < target {
                    rowIndex += 1
                    continue
                }
                let rowResult = testRow(
                    erasedGen, row: row, rowIndex: rowIndex,
                    profile: profile, needsTree: needsTree, property: property
                )
                if let rowResult {
                    onExample?(rowResult.value, rowResult.tree, rowResult.passed)
                    if rowResult.passed == false {
                        return .failure(
                            value: rowResult.value, tree: rowResult.tree, iteration: rowIndex + 1,
                            strength: 2, rows: rowIndex + 1,
                            parameters: paramCount, totalSpace: totalSpace, kind: kind
                        )
                    }
                }
                if skipToRow != nil { break }
                rowIndex += 1
                iterations += 1
            }

            // Only report exhaustive when every point in the full Cartesian product was tested, not just all t-tuples.
            if isExhaustiveCandidate, UInt64(iterations) >= totalSpace {
                return .exhaustive(iterations: iterations)
            }

            return .partial(
                iterations: iterations, strength: 2, rows: rowIndex,
                parameters: paramCount, totalSpace: totalSpace, kind: kind
            )
        }

        // Single parameter: enumerate all values.
        var iterations = 0
        var rowIndex = skipToRow ?? 0
        while rowIndex < budget, UInt64(rowIndex) < domainSizes[0] {
            let row = CoveringArrayRow(values: [UInt64(rowIndex)])
            let rowResult = testRow(
                erasedGen, row: row, rowIndex: rowIndex,
                profile: profile, needsTree: needsTree, property: property
            )
            if let rowResult {
                onExample?(rowResult.value, rowResult.tree, rowResult.passed)
                if rowResult.passed == false {
                    return .failure(
                        value: rowResult.value, tree: rowResult.tree, iteration: rowIndex + 1,
                        strength: 1, rows: rowIndex + 1,
                        parameters: paramCount, totalSpace: totalSpace, kind: kind
                    )
                }
            }
            if skipToRow != nil { break }
            rowIndex += 1
            iterations += 1
        }

        if isExhaustiveCandidate, UInt64(iterations) >= domainSizes[0] {
            return .exhaustive(iterations: iterations)
        }

        return .partial(
            iterations: iterations, strength: 1, rows: rowIndex,
            parameters: paramCount, totalSpace: totalSpace, kind: kind
        )
    }

    // MARK: - Row Testing

    private struct RowResult<Output> {
        let value: Output
        let tree: ChoiceTree
        let passed: Bool
    }

    /// Builds a tree from a covering array row, materializes it, and tests the property.
    ///
    /// Materializes in two phases when `needsTree` is `false`: phase 1 skips ``ChoiceTree`` construction because a passing row's tree is never read, and a failing row triggers a second materialization that builds the real tree for the failure report. Guided materialization is deterministic for a fixed seed and fallback tree, so both phases produce the same value (the same pattern ``SequenceDecoder`` uses).
    ///
    /// Returns `nil` when materialization fails (row is skipped). Otherwise returns the value, its choice tree, and whether the property passed.
    private static func testRow<Output>(
        _ erasedGen: AnyGenerator,
        row: CoveringArrayRow,
        rowIndex: Int,
        profile: any CoverageProfile,
        needsTree: Bool,
        property: (Output) -> Bool
    ) -> RowResult<Output>? {
        guard let tree = profile.buildTree(from: row) else { return nil }

        let mode = Materializer.Mode.guided(
            seed: UInt64(rowIndex),
            fallbackTree: nil
        )
        switch Materializer.materializeAny(
            erasedGen, prefix: ChoiceSequence(), mode: mode, fallbackTree: tree,
            skipTree: needsTree == false,
            collectDecodingReport: false
        ) {
            case let .success(anyValue, freshTree, _):
                // swiftlint:disable:next force_cast
                let value = anyValue as! Output
                let passed = property(value)
                guard needsTree == false, passed == false else {
                    return RowResult(value: value, tree: freshTree, passed: passed)
                }
                // Phase 2: the failure path reads the tree, so rebuild it. Same seed and fallback reproduce phase 1 deterministically; a divergence here cannot happen, and skipping the row is the safe response if it somehow does.
                switch Materializer.materializeAny(
                    erasedGen, prefix: ChoiceSequence(), mode: mode, fallbackTree: tree,
                    collectDecodingReport: false
                ) {
                    case let .success(_, realTree, _):
                        return RowResult(value: value, tree: realTree, passed: passed)
                    case .rejected, .failed:
                        return nil
                }
            case .rejected, .failed:
                return nil
        }
    }
}
