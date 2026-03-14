/// The bind depth a reduction pass targets.
///
/// Replaces the magic `depth: Int` convention where `-1` means "global." Exhaustive switching eliminates silent mishandling of depth categories.
public enum ReductionDepth: Equatable, Hashable, Sendable {
    /// Branch and cross-stage tactics — not filtered by bind depth.
    case global
    /// A specific bind depth: 0 = inner values, 1...max = bound depths.
    case specific(Int)
}
