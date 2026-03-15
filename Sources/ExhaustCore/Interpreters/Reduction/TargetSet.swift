/// Positions in the sequence that an encoder targets.
///
/// Replaces the proliferation of `targetSpans`, `siblingGroups`, `allValueSpans` parameters with a single sum type.
public enum TargetSet {
    /// Individual spans to mutate (value minimization, deletion).
    case spans([ChoiceSpan])
    /// Sibling groups to reorder.
    case siblingGroups([SiblingGroup])
    /// The entire sequence (cross-stage redistribution).
    case wholeSequence
}
