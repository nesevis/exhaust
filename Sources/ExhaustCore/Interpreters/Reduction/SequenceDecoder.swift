/// Materializes a candidate sequence and checks feasibility.
///
/// Selected by ``DecoderContext``, shared by all encoders at a given depth. This is the `dec` map from the paper. Implemented as a concrete enum to avoid heap allocation — decoder types carry associated data that exceeds Swift's three-word inline existential buffer.
///
/// ## Cases
///
/// - ``direct(strictness:)``: Tree-driven materialization. Exact — preserves the candidate exactly.
/// - ``guided(fallbackTree:strictness:)``: ``GuidedMaterializer`` with tiered resolution. Bounded — re-derivation can shift bound values, but the shortlex guard rejects regressions.
/// - ``crossStage(bindIndex:fallbackTree:strictness:)``: Per-candidate routing for cross-stage tactics (depth `.global`, binds present). Routes to direct if only bound values changed, guided if inner values changed.
public enum SequenceDecoder {
    /// Tree-driven materialization. Exact — preserves the candidate exactly.
    case direct(strictness: Interpreters.Strictness)

    /// ``GuidedMaterializer`` with tiered resolution. Bounded — re-derivation can shift bound values, but the shortlex guard rejects regressions.
    case guided(fallbackTree: ChoiceTree?, strictness: Interpreters.Strictness)

    /// Per-candidate routing for cross-stage tactics. Routes to direct if only bound values changed, guided if inner values changed.
    case crossStage(bindIndex: BindSpanIndex, fallbackTree: ChoiceTree?, strictness: Interpreters.Strictness)

    /// The approximation class of this decoder.
    public var approximation: ApproximationClass {
        switch self {
        case .direct: .exact
        case .guided, .crossStage: .bounded
        }
    }

    /// Returns the appropriate decoder for a given context.
    ///
    /// One decoder per context means all encoders sharing a context share the same `dec`, forming a uniform hom-set.
    ///
    /// Three independent reasons trigger non-direct decoders:
    /// 1. Bind re-derivation (`.specific(0)`, binds present): bound content must be re-derived after inner value changes.
    /// 2. Structural invalidity (`.relaxed` strictness): deletion at any depth invalidates the tree's positional mapping.
    /// 3. Cross-stage routing (`.global`, binds present): redistribution may or may not change inner values — routing is per-candidate.
    public static func `for`(_ context: DecoderContext) -> SequenceDecoder {
        switch context.depth {
        case .global:
            if let bindIndex = context.bindIndex, bindIndex.isEmpty == false {
                return .crossStage(
                    bindIndex: bindIndex,
                    fallbackTree: context.fallbackTree,
                    strictness: context.strictness
                )
            }
            return .direct(strictness: context.strictness)

        case .specific(0):
            let needsBindReDerivation = context.bindIndex != nil
                && context.bindIndex?.isEmpty == false
            if needsBindReDerivation || context.strictness == .relaxed {
                return .guided(
                    fallbackTree: context.fallbackTree,
                    strictness: context.strictness
                )
            }
            return .direct(strictness: context.strictness)

        case .specific:
            if context.strictness == .relaxed {
                return .guided(
                    fallbackTree: context.fallbackTree,
                    strictness: context.strictness
                )
            }
            return .direct(strictness: context.strictness)
        }
    }
}
