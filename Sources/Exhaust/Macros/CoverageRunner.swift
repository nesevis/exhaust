// Encapsulates the structured coverage phase of a property test.
//
// Analyzes the generator, then pulls rows from the density algorithm
// (PullBasedCoveringArrayGenerator) one at a time, testing each against the
// property. Stops on first failure or budget.
import ExhaustCore

public enum CoverageRunner {
    public enum Result<Output> {
        /// Coverage found a counterexample.
        case failure(
            value: Output, tree: ChoiceTree,
            iteration: Int, strength: Int, rows: Int,
            parameters: Int, totalSpace: UInt64, kind: String
        )
        /// Exhaustive coverage passed — entire space tested, skip random phase.
        case exhaustive(iterations: Int)
        /// Partial coverage completed — proceed to random phase.
        case partial(
            iterations: Int, strength: Int, rows: Int,
            parameters: Int, totalSpace: UInt64, kind: String
        )
        /// Analysis found nothing to cover — skip to random.
        case notApplicable
    }

    public static func run<Output>(
        _ gen: ReflectiveGenerator<Output>,
        coverageBudget: UInt64,
        property: (Output) -> Bool
    ) -> Result<Output> {
        guard let analysis = ChoiceTreeAnalysis.analyze(gen) else {
            return .notApplicable
        }

        let profile: any CoverageProfile
        let kind: String
        let isExhaustiveCandidate: Bool

        switch analysis {
        case let .finite(finiteProfile):
            profile = finiteProfile
            kind = "finite"
            // Exhaustive when the full space fits within budget and no binds.
            isExhaustiveCandidate = finiteProfile.totalSpace <= coverageBudget
                && finiteProfile.originalTree?.containsBind == false

        case let .boundary(boundaryProfile):
            profile = boundaryProfile
            kind = "boundary"
            isExhaustiveCandidate = false
        }

        let domainSizes = profile.domainSizes
        let paramCount = profile.parameterCount
        let totalSpace = profile.totalSpace
        let budget = Int(min(coverageBudget, UInt64(Int.max)))

        guard paramCount >= 1 else { return .notApplicable }

        // Pull-based pairwise coverage for 2+ parameters.
        if paramCount >= 2 {
            // Use the highest strength the space can support for exhaustive candidates.
            let strength = isExhaustiveCandidate ? min(paramCount, 4) : 2
            var generator = PullBasedCoveringArrayGenerator(
                domainSizes: domainSizes,
                strength: strength
            )
            defer { generator.deallocate() }

            var iterations = 0
            var rowIndex = 0
            while rowIndex < budget, let row = generator.next() {
                let result = testRow(
                    gen, row: row, rowIndex: rowIndex,
                    profile: profile, property: property
                )
                if let result {
                    return .failure(
                        value: result.value, tree: result.tree, iteration: iterations + 1,
                        strength: strength, rows: rowIndex + 1,
                        parameters: paramCount, totalSpace: totalSpace, kind: kind
                    )
                }
                rowIndex += 1
                iterations += 1
            }

            // If the generator exhausted all tuples, the entire space was covered.
            if generator.totalRemaining == 0, isExhaustiveCandidate {
                return .exhaustive(iterations: iterations)
            }

            return .partial(
                iterations: iterations, strength: strength, rows: rowIndex,
                parameters: paramCount, totalSpace: totalSpace, kind: kind
            )
        }

        // Single parameter: enumerate all values.
        var iterations = 0
        var rowIndex = 0
        while rowIndex < budget, UInt64(rowIndex) < domainSizes[0] {
            let row = CoveringArrayRow(values: [UInt64(rowIndex)])
            let result = testRow(
                gen, row: row, rowIndex: rowIndex,
                profile: profile, property: property
            )
            if let result {
                return .failure(
                    value: result.value, tree: result.tree, iteration: iterations + 1,
                    strength: 1, rows: rowIndex + 1,
                    parameters: paramCount, totalSpace: totalSpace, kind: kind
                )
            }
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

    private struct RowFailure<Output> {
        let value: Output
        let tree: ChoiceTree
    }

    /// Builds a tree from a covering array row, materializes it, and tests the property.
    private static func testRow<Output>(
        _ gen: ReflectiveGenerator<Output>,
        row: CoveringArrayRow,
        rowIndex: Int,
        profile: any CoverageProfile,
        property: (Output) -> Bool
    ) -> RowFailure<Output>? {
        guard let tree = profile.buildTree(from: row) else { return nil }

        let prefix = ChoiceSequence(tree)
        let mode = Materializer.Mode.guided(
            seed: UInt64(rowIndex),
            fallbackTree: nil
        )
        switch Materializer.materialize(
            gen, prefix: prefix, mode: mode
        ) {
        case let .success(value, freshTree, _):
            if property(value) == false {
                return RowFailure(value: value, tree: freshTree)
            }
            return nil
        case .rejected(_), .failed(_):
            return nil
        }
    }
}
