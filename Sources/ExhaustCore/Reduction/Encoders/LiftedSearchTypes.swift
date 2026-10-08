/// Keeps a candidate prefix and its reported mutation together without feeding acceptance back into proposal generation.
struct LiftProposal {
    let prefix: ChoiceSequence
    let mutation: EncoderProbe
}

/// Retains the lifted sequence so factories can reject its length before building a graph.
struct LiftResult {
    let tree: ChoiceTree
    let sequence: ChoiceSequence
}

/// Separates a constructed but potentially empty search from an unusable lift.
enum DownstreamBuild {
    case stage(encoder: EncoderDispatch, scope: EncoderInput)
    case failed(DownstreamBuildFailure)
}

/// Describes why construction stopped after an attempted lift.
enum DownstreamBuildFailure {
    case materializationFailed
    case liftedTooLong
    case bindNotFound
    case noDownstreamLeaves
    case sinkValueMismatch
}

/// Fixes operation contracts and accounting independently of the stats label. The optional build limits belong only to bound-value chains.
struct CompositionPolicy {
    let stageBudget: Int?
    let totalProbeCap: Int
    let chainLimits: NestedChainLimits?
    let requiresExactDecoder: Bool
    let acceptanceHandling: AcceptanceHandling
    /// Counts attempted lifts at this site; nil when a run-wide tally owns materialization accounting.
    let liftSite: MaterializationSite?
    /// Reports constructed stages as upstream work, independently of the encoder's stats label.
    let reportsConstructedStages: Bool

    init(
        stageBudget: Int? = 15,
        totalProbeCap: Int = 0,
        chainLimits: NestedChainLimits? = nil,
        requiresExactDecoder: Bool = true,
        acceptanceHandling: AcceptanceHandling = .refreshAndIdle,
        liftSite: MaterializationSite? = nil,
        reportsConstructedStages: Bool = true
    ) {
        self.stageBudget = stageBudget
        self.totalProbeCap = totalProbeCap
        self.chainLimits = chainLimits
        self.requiresExactDecoder = requiresExactDecoder
        self.acceptanceHandling = acceptanceHandling
        self.liftSite = liftSite
        self.reportsConstructedStages = reportsConstructedStages
    }
}

/// Counts spent work independently of active and suspended stages so acceptance cannot erase it.
struct LiftLedger {
    var attempts = 0
    var constructedStages = 0
    var emittedProbes = 0
}
