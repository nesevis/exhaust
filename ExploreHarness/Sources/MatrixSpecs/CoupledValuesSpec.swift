import ExecuteFixture
import Exhaust

/// The shared spec for the `CoupledStore` fixture (fault C — registry in `CoupledStore.swift`).
///
/// Three uniform-weight commands, no precondition skips: a probe before any setKey is a legal no-op.
@StateMachine(.sequential)
public final class CoupledValuesSpec {
    @SystemUnderTest var store: CoupledStore = .init()

    @Invariant
    func notCorrupted() -> Bool {
        store.isCorrupted == false
    }

    @Command(weight: 1, .int(in: 0 ... 15))
    func setKey(key: Int) throws {
        store.setKey(key)
    }

    @Command(weight: 1, .int(in: 0 ... 15))
    func probe(key: Int) throws {
        store.probe(key)
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func pad(value: Int) throws {
        store.pad(value)
    }

    /// Reports the store state at the point of failure.
    public func failureDescription() -> String? {
        "key: \(store.currentKey), corrupted: \(store.isCorrupted)"
    }
}
