/// How a drain ended, and for a timeout whether the abandoned work is still running.
///
/// A caller that only asks "did this time out" cannot tell a probe whose work stopped from one whose tasks are still executing the system under test. The second keeps consuming the process and keeps recording coverage against later attempts, so a search cannot treat the two the same way.
package enum ExecutionDisposition: Equatable, Sendable {
    /// The drain reached its terminal condition.
    case completed
    /// The idle timeout fired and the cancellation drain then completed, so nothing from this probe is still running.
    case timedOutQuiesced
    /// The idle timeout fired and cancellation did not drain either, so the probe's tasks were abandoned while still running.
    case timedOutEscaped
}
