// Encapsulates the structured coverage phase of a property test.
//
// Implements the analysis hierarchy: exhaustive → t-way → boundary.
import ExhaustCore

enum CoverageRunner {
    enum Result<Output> {
        /// Coverage found a counterexample.
        case failure(value: Output, tree: ChoiceTree, iteration: Int)
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
    }

    static func run<Output>(
        _ gen: ReflectiveGenerator<Output>,
        coverageBudget: UInt64,
        property: (Output) -> Bool,
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
        property: (Output) -> Bool,
    ) -> Result<Output> {
        let isExhaustive = profile.totalSpace <= coverageBudget

        let covering: CoveringArray?
        if isExhaustive {
            covering = CoveringArray.generate(profile: profile, strength: profile.parameters.count)
        } else {
            covering = CoveringArray.bestFitting(budget: coverageBudget, profile: profile)
        }

        guard let covering, covering.strength >= 2 else {
            return .notApplicable
        }

        var iterations = 0
        for row in covering.rows {
            guard let tree = CoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }
            guard let value: Output = try? Interpreters.replay(gen, using: tree) else {
                continue
            }
            iterations += 1
            if property(value) == false {
                return .failure(value: value, tree: tree, iteration: iterations)
            }
        }

        if isExhaustive {
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
        property: (Output) -> Bool,
    ) -> Result<Output> {
        guard let covering = CoveringArray.bestFitting(budget: coverageBudget, boundaryProfile: profile) else {
            return .notApplicable
        }
        guard covering.strength >= 2 else {
            return .notApplicable
        }

        var iterations = 0
        for row in covering.rows {
            guard let tree = BoundaryCoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }
            guard let value: Output = try? Interpreters.replay(gen, using: tree) else {
                continue
            }
            iterations += 1
            if property(value) == false {
                return .failure(value: value, tree: tree, iteration: iterations)
            }
        }

        return .partial(
            iterations: iterations,
            strength: covering.strength,
            rows: covering.rows.count,
            parameters: profile.parameters.count,
            totalSpace: covering.profile.totalSpace,
            kind: .boundaryValue
        )
    }
}
