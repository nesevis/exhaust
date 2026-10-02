@testable import ExhaustCore

/// Minimal ``ProbeSessionState`` for driving a ``ProbeSession`` against a closure property outside the reduction machine.
struct ProbeSessionFixtureState: ProbeSessionState {
    var sequence: ChoiceSequence
    var tree: ChoiceTree
    var output: Any
    var graph: ChoiceGraph
    var gen: AnyGenerator
    let property: (Any) -> Bool
    let probeWrapper: ProbeWrapper? = nil
    var rejectCache: Set<UInt64> = []
    let collectStats = true
    let isInstrumented = false

    /// Starts the encoder the scheduler selects for `scope` and wraps it in a probe session based on this state's sequence.
    func makeSession(for scope: EncoderInput) -> ProbeSession {
        var encoder = ChoiceGraphScheduler.selectEncoder(for: scope.transformation.operation, gen: gen)
        encoder.start(scope: scope)
        return ProbeSession(
            encoder: encoder,
            transformation: scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: false
        )
    }
}

extension DispatchPriority {
    /// A priority with no benefit, for transformations a test dispatches directly instead of through the scheduler's queue.
    static let zeroBenefit = DispatchPriority(
        structuralBenefit: 0,
        valueBenefit: 0,
        reductionMagnitude: 0,
        estimatedCost: 1
    )
}
