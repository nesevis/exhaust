import SpecFixture
import Testing

@Suite("ThresholdLedger reproducer smoke tests")
struct ThresholdLedgerSmokeTests {
    // MARK: - Fault J (unspent accumulation)

    @Test("Accumulation triggers exactly at the threshold", arguments: [40, 90], [false, true])
    func accumulationThreshold(threshold: Int, laddered: Bool) {
        var ledger = ThresholdLedger(threshold: threshold, laddered: laddered)
        for _ in 0 ..< (threshold + 8) / 9 - 1 {
            ledger.accumulate(9)
            #expect(ledger.isCorrupted == false)
        }
        ledger.accumulate(9)
        #expect(ledger.isCorrupted)
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
}
