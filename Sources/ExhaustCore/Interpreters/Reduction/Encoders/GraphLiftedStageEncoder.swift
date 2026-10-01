/// Keeps the lifted first probe and optional bound covering in one stage, so scheduling and stage accounting cannot introduce a boundary between them.
struct GraphLiftedStageEncoder: GraphEncoder {
    let name: EncoderName
    private let mutation: EncoderProbe
    private let boundRange: ClosedRange<Int>?
    private var pending: ChoiceSequence?
    private var covering = BoundValueCoveringEncoder()

    init(name: EncoderName, mutation: EncoderProbe, boundRange: ClosedRange<Int>? = nil) {
        self.name = name
        self.mutation = mutation
        self.boundRange = boundRange
    }

    mutating func start(scope: EncoderInput) {
        pending = scope.baseSequence
        if let boundRange {
            covering.start(sequence: scope.baseSequence, tree: scope.tree, positionRange: boundRange)
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        if let pending {
            self.pending = nil
            candidate = pending
            return mutation
        }
        guard let probe = covering.nextProbe(lastAccepted: lastAccepted) else {
            return nil
        }
        candidate = probe
        return mutation
    }
}
