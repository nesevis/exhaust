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
        // When the original tree contains bind nodes, coverage only exhausts the inner
        // parameter space — the bound subtree varies per inner value and isn't covered.
        // Never treat such generators as exhaustive so the random phase always runs.
        let hasBinds = profile.originalTree?.containsBind ?? false
        let isExhaustive = profile.totalSpace <= coverageBudget && hasBinds == false

        let covering: CoveringArray? = if isExhaustive {
            CoveringArray.generate(profile: profile, strength: profile.parameters.count)
        } else {
            CoveringArray.bestFitting(budget: coverageBudget, profile: profile)
                // bestFitting requires ≥2 parameters; fall back to strength-1 for single-parameter profiles
                ?? CoveringArray.generate(profile: profile, strength: 1)
        }

        guard let covering, covering.strength >= 1 else {
            return .notApplicable
        }

        let skipFilterCheck = covering.rows.count >= 100

        var iterations = 0
        for (rowIndex, row) in covering.rows.enumerated() {
            guard let tree = CoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }

            let value: Output?
            if hasBinds {
                // Bind-aware replay: flatten the full tree (including bind markers) to a prefix
                // and use GuidedMaterializer. The cursor skips bind-bound content and suspends
                // prefix consumption so the bound subtree is generated fresh via PRNG, while
                // sibling parameters after the bind stay correctly aligned.
                let prefix = ChoiceSequence(tree)
                switch GuidedMaterializer.materialize(gen, prefix: prefix, seed: UInt64(rowIndex), abortOnFilter: skipFilterCheck) {
                case let .success(v, _, _):
                    value = v
                case .filterEncountered:
                    return .notApplicable
                case .failed:
                    value = nil
                }
            } else {
                value = try? Interpreters.replay(gen, using: tree)
            }

            guard let value else { continue }
            iterations += 1
            if property(value) == false {
                return .failure(value: value, tree: tree, iteration: iterations)
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
            kind: .finiteDomain,
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
        // Strength 1 is valid for boundary coverage (test all boundary values for
        // each parameter). Unlike finite-domain coverage where t>=2 ensures pairwise
        // interaction, boundary coverage aims to hit every interesting value.
        guard covering.strength >= 1 else {
            return .notApplicable
        }

        let hasBinds = profile.originalTree?.containsBind ?? false
        let skipFilterCheck = covering.rows.count >= 100

        var iterations = 0
        for (rowIndex, row) in covering.rows.enumerated() {
            guard let tree = BoundaryCoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }

            let value: Output?
            if hasBinds {
                let prefix = ChoiceSequence(tree)
                switch GuidedMaterializer.materialize(gen, prefix: prefix, seed: UInt64(rowIndex), abortOnFilter: skipFilterCheck) {
                case let .success(v, _, _):
                    value = v as? Output
                case .filterEncountered:
                    return .notApplicable
                case .failed:
                    value = nil
                }
            } else {
                value = try? Interpreters.replay(gen, using: tree)
            }

            guard let value else { continue }
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
            kind: .boundaryValue,
        )
    }
}
