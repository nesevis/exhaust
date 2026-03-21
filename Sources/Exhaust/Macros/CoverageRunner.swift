// Encapsulates the structured coverage phase of a property test.
//
// Implements the analysis hierarchy via CoverageStrategy protocol dispatch:
// exhaustive → t-way → single-parameter (finite) and boundary (boundary).
import ExhaustCore

enum CoverageRunner {
    enum Result<Output> {
        /// Coverage found a counterexample.
        case failure(value: Output, tree: ChoiceTree, iteration: Int, strength: Int, rows: Int, parameters: Int, totalSpace: UInt64, kind: CoverageKind)
        /// Exhaustive coverage passed — entire space tested, skip random phase.
        case exhaustive(iterations: Int)
        /// Partial coverage completed — proceed to random phase.
        case partial(iterations: Int, strength: Int, rows: Int, parameters: Int, totalSpace: UInt64, kind: CoverageKind)
        /// Analysis found nothing to cover — skip to random.
        case notApplicable
    }

    enum CoverageKind {
        case finiteDomain
        case boundaryValue
        /// Per-length partitioned boundary coverage. Pairwise coverage is within each
        /// length partition, not across all parameters including length.
        case perLengthBoundaryValue
    }

    static func run<Output>(
        _ gen: ReflectiveGenerator<Output>,
        coverageBudget: UInt64,
        property: (Output) -> Bool
    ) -> Result<Output> {
        guard let analysis = ChoiceTreeAnalysis.analyze(gen) else {
            return .notApplicable
        }

        switch analysis {
        case let .finite(profile):
            return runFinite(gen, profile: profile, coverageBudget: coverageBudget, property: property)

        case let .boundary(boundaryProfile):
            return runBoundary(gen, profile: boundaryProfile, coverageBudget: coverageBudget, property: property)
        }
    }

    private static func runFinite<Output>(
        _ gen: ReflectiveGenerator<Output>,
        profile: FiniteDomainProfile,
        coverageBudget: UInt64,
        property: (Output) -> Bool
    ) -> Result<Output> {
        let hasBinds = profile.originalTree?.containsBind ?? false

        // Build strategy chain ordered by phase (strongest first).
        // The first strategy that returns a non-nil covering array wins.
        let strategies: [any CoverageStrategy] = [
            ExhaustiveCoverageStrategy(hasBinds: hasBinds),
            TWayCoverageStrategy(),
            SingleParameterCoverageStrategy(),
        ]

        var covering: CoveringArray?
        var isExhaustive = false
        for strategy in strategies {
            if let result = strategy.generate(profile: profile, budget: coverageBudget) {
                covering = result
                isExhaustive = strategy.phase == .exhaustive
                break
            }
        }

        guard let covering, covering.strength >= 1 else {
            return .notApplicable
        }

        var iterations = 0
        for (rowIndex, row) in covering.rows.enumerated() {
            guard let tree = CoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }

            let value: Output?
            var materializerTree: ChoiceTree?
            let prefix = ChoiceSequence(tree)
            switch ReductionMaterializer.materialize(gen, prefix: prefix, mode: .guided(seed: UInt64(rowIndex), fallbackTree: nil)) {
            case let .success(v, freshTree, _):
                value = v
                materializerTree = freshTree
            case .rejected, .failed:
                value = nil
            }

            guard let value, let materializerTree else { continue }
            iterations += 1
            if property(value) == false {
                ExhaustLog.debug(
                    category: .propertyTest,
                    event: "coverage_counterexample",
                    "Coverage found counterexample at row \(rowIndex): \(value)"
                )
                return .failure(
                    value: value, tree: materializerTree, iteration: iterations,
                    strength: covering.strength, rows: covering.rows.count,
                    parameters: profile.parameters.count, totalSpace: profile.totalSpace,
                    kind: .finiteDomain
                )
            }
        }

        if isExhaustive, iterations == covering.rows.count {
            return .exhaustive(iterations: iterations)
        }

        return .partial(
            iterations: iterations,
            strength: covering.strength,
            rows: covering.rows.count,
            parameters: profile.parameters.count,
            totalSpace: profile.totalSpace,
            kind: .finiteDomain
        )
    }

    private static func runBoundary<Output>(
        _ gen: ReflectiveGenerator<Output>,
        profile: BoundaryDomainProfile,
        coverageBudget: UInt64,
        property: (Output) -> Bool
    ) -> Result<Output> {
        let strategy = BoundaryValueCoverageStrategy()
        guard let result = strategy.generate(profile: profile, budget: coverageBudget) else {
            return .notApplicable
        }
        guard result.strength >= 1 else {
            return .notApplicable
        }

        let totalRows = result.totalRows

        // Build the list of (rows, profile) segments to iterate.
        // For flat results, there's one segment using the original profile.
        // For per-length results, each sub-array has its own profile with only accessible element params.
        let segments: [(rows: [CoveringArrayRow], profile: BoundaryDomainProfile)]
        let strength: Int
        let totalSpace: UInt64
        let kind: CoverageKind

        switch result {
        case let .flat(covering):
            segments = [(rows: covering.rows, profile: profile)]
            strength = covering.strength
            totalSpace = covering.profile.totalSpace
            kind = .boundaryValue

        case let .perLength(subArrays):
            segments = subArrays
            strength = result.strength
            totalSpace = UInt64(totalRows)
            kind = .perLengthBoundaryValue
        }

        var iterations = 0
        var globalRowIndex = 0
        for segment in segments {
            for row in segment.rows {
                guard let tree = BoundaryCoveringArrayReplay.buildTree(
                    row: row, profile: segment.profile
                ) else {
                    globalRowIndex += 1
                    continue
                }

                let value: Output?
                var materializerTree: ChoiceTree?
                let prefix = ChoiceSequence(tree)
                switch ReductionMaterializer.materialize(gen, prefix: prefix, mode: .guided(seed: UInt64(globalRowIndex), fallbackTree: nil)) {
                case let .success(v, freshTree, _):
                    value = v
                    materializerTree = freshTree
                case .rejected, .failed:
                    value = nil
                }

                globalRowIndex += 1
                guard let value, let materializerTree else { continue }
                iterations += 1
                if property(value) == false {
                    return .failure(
                        value: value, tree: materializerTree, iteration: iterations,
                        strength: strength, rows: totalRows,
                        parameters: profile.parameters.count, totalSpace: totalSpace,
                        kind: kind
                    )
                }
            }
        }

        return .partial(
            iterations: iterations,
            strength: strength,
            rows: totalRows,
            parameters: profile.parameters.count,
            totalSpace: totalSpace,
            kind: kind
        )
    }
}
