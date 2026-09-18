extension ChoiceTree {
    /// Identifies bind inputs that screening keeps fixed, so their dependent choices can participate in the same covering array without changing shape between rows.
    ///
    /// Depth controls qualify because screening analysis pins them to their size-feasible upper bounds. This does not classify an ordinary sampled integer as a fixed context.
    var isScreeningContext: Bool {
        switch self {
            case .getSize, .just:
                true
            case let .choice(value, _):
                value.tag == .depthControl
            case .group, .bind, .sequence, .resize, .branch:
                false
        }
    }
}
