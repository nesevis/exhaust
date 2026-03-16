/// Determines which ``SequenceDecoder`` to use based on depth and bind state.
///
/// One decoder per context means all encoders sharing a context share the same `dec`, forming a uniform hom-set (paper section 7).
public struct DecoderContext {
    public let depth: ReductionDepth
    public let bindIndex: BindSpanIndex?
    public let fallbackTree: ChoiceTree?
    public let strictness: Interpreters.Strictness
    /// When `true`, use ``ReductionMaterializer``-backed decoders (`.exactFresh` / `.guidedFresh`)
    /// that produce fresh trees with current `validRange` and all branch alternatives.
    public let useReductionMaterializer: Bool
    /// When `true`, pick sites materialize all non-selected branch alternatives.
    /// Only needed for ``PromoteBranchesEncoder`` / ``PivotBranchesEncoder``.
    public let materializePicks: Bool

    public init(
        depth: ReductionDepth,
        bindIndex: BindSpanIndex?,
        fallbackTree: ChoiceTree?,
        strictness: Interpreters.Strictness,
        useReductionMaterializer: Bool = false,
        materializePicks: Bool = false
    ) {
        self.depth = depth
        self.bindIndex = bindIndex
        self.fallbackTree = fallbackTree
        self.strictness = strictness
        self.useReductionMaterializer = useReductionMaterializer
        self.materializePicks = materializePicks
    }
}
