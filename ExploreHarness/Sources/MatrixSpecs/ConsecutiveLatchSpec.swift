import ExecuteFixture
import Exhaust

/// The negative control's spec: one command whose uniform digit argument makes the streak-gated fault blind-improbable. A future feedback channel's differential gate must measure this exact spec shape (one command kind, argument-carried signal) so the gate and the pinned baseline stay comparable.
///
/// Lives in `MatrixSpecs` alongside the matrix specs for the shared-target mechanics, but it is excluded from mechanism gates by charter.
@StateMachine(.sequential)
public final class ConsecutiveLatchSpec {
    @SystemUnderTest var latch: ConsecutiveLatch = .init()

    @Invariant
    func neverTripped() -> Bool {
        latch.isTripped == false
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func pulse(digit: Int) throws {
        latch.pulse(digit)
    }

    /// Reports the latch state at the point of failure.
    public func failureDescription() -> String? {
        "\(latch)"
    }
}
