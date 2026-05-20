import ExhaustCore

/// Runs boundary domain analysis on a generator and returns the profile, or nil if not boundary-analyzable.
package func analyzeBoundary(_ gen: Generator<some Any>) -> BoundaryDomainProfile? {
    guard case let .boundary(profile) = ChoiceTreeAnalysis.analyze(gen) else { return nil }
    return profile
}
