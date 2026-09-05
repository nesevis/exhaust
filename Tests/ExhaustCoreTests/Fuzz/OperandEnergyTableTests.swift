import ExhaustCore
import Testing

@Suite("OperandEnergyTable tests")
struct OperandEnergyTableTests {
    @Test("A source that yields on every draw is never retired", arguments: [3, 11, 42] as [UInt64])
    func yieldingSourceKeepsEnergy(seed: UInt64) {
        var table = OperandEnergyTable(capacityExponent: 4)
        var prng = Xoshiro256(seed: seed)
        let key = prng.next() | 1
        for _ in 0 ..< 500 {
            let hasEnergy = table.hasEnergy(key, initial: 4)
            #expect(hasEnergy)
            table.note(key, yielded: true, initial: 4)
        }
        #expect(table.retirements == 0)
    }

    @Test("A source is retired after exactly its allowance of barren draws and stays retired", arguments: [1, 4, 16] as [UInt8])
    func barrenSourceIsRetired(initial: UInt8) {
        var table = OperandEnergyTable(capacityExponent: 4)
        let key: UInt64 = 0xDEAD_BEEF_0000_0001
        for _ in 0 ..< Int(initial) {
            let hasEnergy = table.hasEnergy(key, initial: initial)
            #expect(hasEnergy)
            table.note(key, yielded: false, initial: initial)
        }
        let hasEnergyAfterAllowance = table.hasEnergy(key, initial: initial)
        #expect(hasEnergyAfterAllowance == false)
        #expect(table.retirements == 1)
        // A retired key never reaches the live table again, so even a yield recorded against it cannot resurrect it.
        table.note(key, yielded: true, initial: initial)
        let hasEnergyAfterYield = table.hasEnergy(key, initial: initial)
        #expect(hasEnergyAfterYield == false)
    }

    @Test("A yield restores the full allowance rather than one draw's worth")
    func yieldRestoresAllowance() {
        var table = OperandEnergyTable(capacityExponent: 4)
        let key: UInt64 = 0x1234_5678_9ABC_DEF1
        for _ in 0 ..< 3 {
            table.note(key, yielded: false, initial: 4)
        }
        table.note(key, yielded: true, initial: 4)
        for _ in 0 ..< 3 {
            table.note(key, yielded: false, initial: 4)
        }
        let hasEnergy = table.hasEnergy(key, initial: 4)
        #expect(hasEnergy)
        #expect(table.retirements == 0)
    }

    @Test("Retirements never exceed the distinct keys drawn, and every seating is counted", arguments: [5, 9, 77] as [UInt64])
    func accountingBounds(seed: UInt64) {
        var table = OperandEnergyTable(capacityExponent: 6)
        var prng = Xoshiro256(seed: seed)
        var keys: Set<UInt64> = []
        for _ in 0 ..< 2000 {
            let key = (prng.next() % 512) | 1
            keys.insert(key)
            if table.hasEnergy(key, initial: 3) {
                table.note(key, yielded: prng.next() % 5 == 0, initial: 3)
            }
        }
        #expect(table.retirements <= keys.count)
        #expect(table.evictions <= table.seatings)
        #expect(table.seatings >= keys.count)
    }

    @Test("Keys sharing a home slot are seated by probing, not by evicting each other")
    func probingSeatsCollidingKeys() {
        // Four keys with identical high bits share one home slot in a 16-slot table; the probe window is wider than that, so none evicts another.
        var table = OperandEnergyTable(capacityExponent: 4)
        let keys: [UInt64] = (1 ... 4).map { UInt64($0) }
        for key in keys {
            for _ in 0 ..< 2 {
                table.note(key, yielded: false, initial: 3)
            }
        }
        #expect(table.evictions == 0)
        for key in keys {
            table.note(key, yielded: false, initial: 3)
            let hasEnergy = table.hasEnergy(key, initial: 3)
            #expect(hasEnergy == false)
        }
        #expect(table.retirements == keys.count)
    }
}
