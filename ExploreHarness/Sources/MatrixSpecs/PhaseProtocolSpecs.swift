import ExecuteFixture
import Exhaust

/// The shared spec for the flat `PhaseSession` fixture (fault O — registry in `PhaseSession.swift`).
///
/// Five uniform-weight commands. No command precondition-skips: `use` while closed must reach the SUT, because that stray call is the fault's final step.
@StateMachine(.sequential)
public final class PhaseProtocolFlatSpec {
    @SystemUnderTest var session: PhaseSession = .init(laddered: false)

    @Invariant
    func notCorrupted() -> Bool {
        session.isCorrupted == false
    }

    @Command(weight: 1)
    func open() throws {
        session.open()
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func configure(setting: Int) throws {
        session.configure(setting)
    }

    @Command(weight: 1)
    func use() throws {
        session.use()
    }

    @Command(weight: 1)
    func close() throws {
        session.close()
    }

    @Command(weight: 1)
    func reset() throws {
        session.reset()
    }

    /// Reports the session state at the point of failure.
    public func failureDescription() -> String? {
        "phase: \(session.phaseName), cycles: \(session.cycleCount), corrupted: \(session.isCorrupted)"
    }
}

/// The laddered `PhaseSession` variant: identical command surface, but each completed-cycle rung lights a distinct edge.
@StateMachine(.sequential)
public final class PhaseProtocolLadderedSpec {
    @SystemUnderTest var session: PhaseSession = .init(laddered: true)

    @Invariant
    func notCorrupted() -> Bool {
        session.isCorrupted == false
    }

    @Command(weight: 1)
    func open() throws {
        session.open()
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func configure(setting: Int) throws {
        session.configure(setting)
    }

    @Command(weight: 1)
    func use() throws {
        session.use()
    }

    @Command(weight: 1)
    func close() throws {
        session.close()
    }

    @Command(weight: 1)
    func reset() throws {
        session.reset()
    }

    /// Reports the session state at the point of failure.
    public func failureDescription() -> String? {
        "phase: \(session.phaseName), cycles: \(session.cycleCount), corrupted: \(session.isCorrupted)"
    }
}
