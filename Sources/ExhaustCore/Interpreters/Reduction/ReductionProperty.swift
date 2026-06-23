/// Distinguishes how the reducer invokes the failing-property check.
///
/// Normal property tests use `.property`, which receives only the materialized output. The two-phase decode optimization (materialize without tree, fast-reject, then rebuild tree for accepted probes) applies.
///
/// Preemptive contract tests use `.contract`, which receives the output **and** the materialized ChoiceTree. The decoder always builds the full tree before calling the closure, so the contract's linearizability checker can derive per-command observation hashes from the reduced tree rather than a stale original.
package indirect enum ReductionProperty {
    case property((Any) -> Bool)
    case contract((Any, ChoiceTree) -> Bool)
}
