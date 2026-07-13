import ExecuteFixture
import Testing

@Suite("BranchyRouter reproducer smoke tests")
struct BranchyRouterSmokeTests {
    // MARK: - Fault B (armed consecutive opcode pair)

    @Test("Fault B fires on the registry minimal")
    func faultBMinimal() throws {
        var router = BranchyRouter()
        try router.route(opcode: 3, operand: 7)
        try router.route(opcode: 9, operand: 5)
        try router.route(opcode: 12, operand: 0)
        #expect(throws: BranchyRouterError.corruption) {
            try router.route(opcode: 5, operand: 0)
        }
    }

    @Test("Fault B does not fire without the armed mode (strict prefix)")
    func faultBNeedsArmedMode() throws {
        var router = BranchyRouter()
        try router.route(opcode: 3, operand: 7)
        try router.route(opcode: 12, operand: 0)
        try router.route(opcode: 5, operand: 0)
        #expect(router.mode == 1, "elevated but never armed; the pair alone is harmless")
    }

    @Test("Fault B does not fire when the pair is separated")
    func faultBNeedsConsecutivePair() throws {
        var router = BranchyRouter()
        try router.route(opcode: 3, operand: 7)
        try router.route(opcode: 9, operand: 5)
        try router.route(opcode: 12, operand: 0)
        try router.route(opcode: 11, operand: 0)
        try router.route(opcode: 5, operand: 0)
        #expect(router.mode == 2, "an intervening opcode breaks the consecutive pair")
    }

    @Test("Fault B does not fire when reset intervenes")
    func faultBResetDisarms() throws {
        var router = BranchyRouter()
        try router.route(opcode: 3, operand: 7)
        try router.route(opcode: 9, operand: 5)
        try router.route(opcode: 0, operand: 3)
        try router.route(opcode: 12, operand: 0)
        try router.route(opcode: 5, operand: 0)
        #expect(router.mode == 0, "reset drops the mode ladder")
    }

    @Test("Elevation requires a high operand")
    func elevationNeedsHighOperand() throws {
        var router = BranchyRouter()
        try router.route(opcode: 3, operand: 6)
        #expect(router.mode == 0, "operand 6 is below the elevation threshold of 7")
        try router.route(opcode: 3, operand: 7)
        #expect(router.mode == 1)
    }

    @Test("Arming requires the elevated mode")
    func armingNeedsElevatedMode() throws {
        var router = BranchyRouter()
        try router.route(opcode: 9, operand: 5)
        #expect(router.mode == 0, "opcode 9 arms only from mode 1")
    }

    @Test("A tiny operand on the arm opcode de-arms")
    func tinyOperandDearms() throws {
        var router = BranchyRouter()
        try router.route(opcode: 3, operand: 7)
        try router.route(opcode: 9, operand: 5)
        #expect(router.mode == 2)
        try router.route(opcode: 9, operand: 1)
        #expect(router.mode == 1, "arm opcode with operand < 2 drops armed back to elevated")
    }
}
