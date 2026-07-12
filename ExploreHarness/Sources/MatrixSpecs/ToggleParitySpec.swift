import ExecuteFixture
import Exhaust

/// The shared spec for the `ToggleCounter` fixture (fault T — registry in `ToggleCounter.swift`).
///
/// Three uniform-weight commands, no precondition skips.
@StateMachine(.sequential)
public final class ToggleParitySpec {
    @SystemUnderTest var counter: ToggleCounter = .init()

    @Invariant
    func notCorrupted() -> Bool {
        counter.isCorrupted == false
    }

    @Command(weight: 1)
    func toggle() throws {
        counter.toggle()
    }

    @Command(weight: 1)
    func checkpoint() throws {
        counter.checkpoint()
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func pad(value: Int) throws {
        counter.pad(value)
    }

    /// Reports the counter state at the point of failure.
    public func failureDescription() -> String? {
        "toggles: \(counter.count), corrupted: \(counter.isCorrupted)"
    }
}
