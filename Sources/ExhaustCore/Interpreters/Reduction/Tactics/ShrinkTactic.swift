//
//  ShrinkTactic.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

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
/// At depth 0, mutations to inner values trigger re-derivation of all bound content via
/// ``GuidedMaterializer``. At depth > 0, targeted spans are inside bound subtrees —
/// mutations here don't change the inner generator, so re-derivation is unnecessary.
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
    /// Updated after each accepted tactic, providing the most recent consistent tree
    /// for bound-value clamping. Used by ``TacticEvaluation.evaluate()`` when the
    /// tree parameter is not directly available.
    public let fallbackTree: ChoiceTree?
}

/// Categorizes which kind of spans a deletion tactic targets.
enum DeletionSpanCategory {
    case containerSpans
    case sequenceElements
    case sequenceBoundaries
    case freeStandingValues
    case siblingGroups
    case mixed
}

/// Pairs a deletion tactic with its span category for lattice-aware span routing.
struct DeletionTacticEntry {
    let tactic: any ShrinkTactic
    let spanCategory: DeletionSpanCategory
}

/// Categorizes which bind-stage content types a tactic applies to.
public enum TacticApplicability: Hashable, Sendable {
    /// Integral value reduction (zero, binary search).
    case numericValues
    /// Float/double value reduction (special values, truncation, integer domain, ratio).
    case floatValues
    /// Deletion tactics (container spans, sequence elements, free-standing values, boundaries).
    case containers
    /// Branch manipulation (promote, pivot).
    case branches
    /// Sibling reordering.
    case ordering
    /// Cross-stage tactics (tandem, redistribute) — not filtered by depth.
    case crossStage
}

/// A single shrink tactic that can be applied to a choice sequence.
///
/// Each tactic encapsulates one reduction strategy (e.g. "binary search values toward zero",
/// "delete container spans"). Tactics produce new (sequence, tree, output) triples via
/// ``GuidedMaterializer`` internally — the tree is always re-derived from materialization.
public protocol ShrinkTactic {
    /// Human-readable name for logging and debugging.
    var name: String { get }

    /// Which bind-stage content types this tactic applies to.
    var applicability: TacticApplicability { get }

    /// Attempt to shrink the sequence.
    ///
    /// - Parameters:
    ///   - gen: The reflective generator.
    ///   - sequence: The current choice sequence.
    ///   - tree: The current choice tree.
    ///   - targetSpans: The spans this tactic should operate on (pre-filtered by the caller to
    ///     the relevant bind depth and content type).
    ///   - context: Depth and bind context for this tactic application.
    ///   - property: The property under test — returns `true` for passing inputs.
    ///   - rejectCache: Shared rejection cache for deduplication.
    /// - Returns: A ``ShrinkResult`` on improvement, or `nil` if no shrink was found.
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

/// A tactic that can mutate branch/tree structure, returning a new tree alongside the sequence.
///
/// Branch tactics (promote, pivot) operate on the tree directly rather than on spans within
/// a sequence, so they use a different application signature.
public protocol BranchShrinkTactic {
    var name: String { get }
    var applicability: TacticApplicability { get }

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        context: TacticContext,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>?
}

/// A tactic that operates on sibling groups rather than individual spans.
public protocol SiblingGroupShrinkTactic {
    var name: String { get }
    var applicability: TacticApplicability { get }

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        siblingGroups: [SiblingGroup],
        context: TacticContext,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>?
}

/// A tactic that operates across all bind depths (tandem, redistribute).
protocol CrossStageShrinkTactic {
    var name: String { get }

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        siblingGroups: [SiblingGroup],
        allValueSpans: [ChoiceSpan],
        context: TacticContext,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>?
}
