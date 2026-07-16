/// The number of concurrent execution lanes for a `.tasks` or `.threads` spec.
///
/// The cases enumerate the supported range (one through four) so an out-of-range value cannot be expressed. The runner uses `RawRepresentable.rawValue` directly as the lane count, so no validation or clamping is required.
public enum ConcurrencyLevel: Int, CaseIterable, Sendable {
    /// One lane — commands run sequentially with no interleaving.
    case one = 1
    /// Two concurrent lanes.
    case two = 2
    /// Three concurrent lanes.
    case three = 3
    /// Four concurrent lanes.
    case four = 4
}
