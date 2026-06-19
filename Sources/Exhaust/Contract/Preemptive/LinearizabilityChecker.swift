import ExhaustCore

/// Linearizability verdict used by the preemptive pipeline and ``PreemptiveBackend`` protocol.
///
/// Wraps ``LinearizabilityChecker/Result`` from ExhaustCore with the same cases so the pipeline does not depend on the generic checker's type parameter.
enum LinearizabilityResult {
    case linearizable
    case notLinearizable(closestOrdering: [String], divergenceStep: Int)

    init(_ coreResult: LinearizabilityChecker<some Any>.Result) {
        switch coreResult {
            case .linearizable:
                self = .linearizable
            case let .notLinearizable(closestOrdering, divergenceStep):
                self = .notLinearizable(closestOrdering: closestOrdering, divergenceStep: divergenceStep)
        }
    }
}
