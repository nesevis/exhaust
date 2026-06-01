import ExhaustCore

/// Runs large-domain analysis on a generator and returns the profile, or nil if not analyzable.
package func analyzeLargeDomain(_ gen: Generator<some Any>, expand: Bool = true) -> LargeDomainProfile? {
    guard case let .large(profile) = ChoiceTreeAnalysis.analyze(gen, expandSequencePairs: expand) else { return nil }
    return profile
}
