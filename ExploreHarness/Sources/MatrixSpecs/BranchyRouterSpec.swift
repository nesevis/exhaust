import ExecuteFixture
import Exhaust

/// The shared spec for the `BranchyRouter` fixture (fault B — registry in `BranchyRouter.swift`).
///
/// One command with a wide two-argument domain: the router's structure lives in its 16 handlers, not in the command vocabulary.
@StateMachine(.sequential)
public final class BranchyRouterSpec {
    @SystemUnderTest var router: BranchyRouter = .init()

    @Command(weight: 1, .int(in: 0 ... 15), .int(in: 0 ... 9))
    func route(opcode: Int, operand: Int) throws {
        try router.route(opcode: opcode, operand: operand)
    }

    /// Reports the router state at the point of failure.
    public func failureDescription() -> String? {
        "mode: \(router.mode), registers: \(router.registers)"
    }
}
