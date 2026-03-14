/// The result of a successful tactic application.
public struct ShrinkResult<Output> {
    public let sequence: ChoiceSequence
    public let tree: ChoiceTree
    public let output: Output
    /// Number of property evaluations consumed by this application.
    public let evaluations: Int
}

/// Depth and bind context passed to every tactic.
///
/// At depth 0, mutations to inner values trigger re-derivation of all bound content via ``GuidedMaterializer``. At depth > 0, targeted spans are inside bound subtrees — mutations here don't change the inner generator, so re-derivation is unnecessary.
public struct TacticContext {
    /// The bind span index for the current sequence (`nil` when no binds present).
    public let bindIndex: BindSpanIndex?
    /// The bind depth this tactic is operating at.
    /// - `0` means top-level (inner generator values).
    /// - `> 0` means inside a bound subtree at the given nesting depth.
    /// - `-1` is used for global tactics (branch, cross-stage) that don't target a specific depth.
    public let depth: Int
    /// Fallback tree for ``GuidedMaterializer`` re-derivation.
    ///
    /// Updated after each accepted tactic, providing the most recent consistent tree for bound-value clamping.
    public let fallbackTree: ChoiceTree?
}

/// Categorizes which kind of spans a deletion encoder targets.
enum DeletionSpanCategory {
    case containerSpans
    case sequenceElements
    case sequenceBoundaries
    case freeStandingValues
    case siblingGroups
    case mixed
}

/// Categorizes which bind-stage content types a tactic applies to.
public enum TacticApplicability: Hashable, Sendable {
    case numericValues
    case floatValues
    case containers
    case branches
    case ordering
    case crossStage
}

/// A single shrink tactic that can be applied to a choice sequence.
///
/// Legacy protocol retained for tactics not yet extracted as encoders (``ReduceFloatTactic``, ``DeleteAlignedWindowsTactic``).
public protocol ShrinkTactic {
    var name: String { get }
    var applicability: TacticApplicability { get }

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        context: TacticContext,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>?
}
