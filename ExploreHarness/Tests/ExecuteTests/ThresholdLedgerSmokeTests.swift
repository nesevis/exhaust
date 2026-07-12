import ExecuteFixture
import Testing

@Suite("ThresholdLedger reproducer smoke tests")
struct ThresholdLedgerSmokeTests {
    // MARK: - Fault J (unspent accumulation)

    @Test("Fault J fires at threshold 40 on five max accumulates (registry minimal)")
    func faultJMinimal40() {
        var ledger = ThresholdLedger(threshold: 40)
        for _ in 0 ..< 5 {
            ledger.accumulate(9)
        }
        #expect(ledger.isCorrupted, "five accumulate(9) reach sum 45")
    }

    @Test("Fault J fires at threshold 90 on ten max accumulates (registry minimal)")
    func faultJMinimal90() {
        var ledger = ThresholdLedger(threshold: 90)
        for _ in 0 ..< 10 {
            ledger.accumulate(9)
        }
        #expect(ledger.isCorrupted, "ten accumulate(9) reach sum 90")
    }

    @Test("Fault J does not fire one accumulate short (strict prefix)")
    func faultJPrefixSafe() {
        var ledger = ThresholdLedger(threshold: 40)
        for _ in 0 ..< 4 {
            ledger.accumulate(9)
        }
        #expect(ledger.isCorrupted == false, "sum 36 is below threshold 40")
    }

    @Test("Fault J does not fire when a spend intervenes")
    func faultJSpendResets() {
        var ledger = ThresholdLedger(threshold: 40)
        for _ in 0 ..< 4 {
            ledger.accumulate(9)
        }
        ledger.spend()
        for _ in 0 ..< 4 {
            ledger.accumulate(9)
        }
        #expect(ledger.isCorrupted == false, "spend zeroes the balance; neither window reaches 40")
    }

    @Test("Non-qualifying values add nothing")
    func nonQualifyingValuesAddNothing() {
        var ledger = ThresholdLedger(threshold: 40)
        for _ in 0 ..< 20 {
            ledger.accumulate(5)
        }
        #expect(ledger.currentBalance == 0, "values 0...5 never accumulate")
        #expect(ledger.isCorrupted == false)
    }

    @Test("Audit reads the balance without disturbing it")
    func auditReadsWithoutDisturbing() {
        var ledger = ThresholdLedger(threshold: 40)
        ledger.accumulate(7)
        ledger.audit()
        #expect(ledger.lastAudit == 7)
        #expect(ledger.currentBalance == 7)
    }

    @Test("The laddered variant shares the flat variant's trigger")
    func ladderedVariantSameTrigger() {
        var ledger = ThresholdLedger(threshold: 90, laddered: true)
        for _ in 0 ..< 10 {
            ledger.accumulate(9)
        }
        #expect(ledger.isCorrupted, "laddered changes the coverage surface, never the trigger")
    }
}
