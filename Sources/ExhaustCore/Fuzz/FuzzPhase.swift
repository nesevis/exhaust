/// The phase of a `#explore(time:)` run that produced a corpus entry or discovered a fault cluster.
///
/// Recorded on corpus entries and clusters so the report can attribute findings (the harness asserts, for example, that a boundary-value bug is discovered by screening rather than the mutation phase), and so harness tests can start the loop at a chosen phase.
package enum FuzzPhase: String, Sendable, Equatable {
    /// Phase 1: covering-array screening, inherited from `#exhaust`.
    case screening
    /// Phase 2: PRNG-driven random sampling, inherited from `#exhaust`.
    case sampling
    /// Phase 3: mutation-based exploration from corpus parents.
    case mutation
}
