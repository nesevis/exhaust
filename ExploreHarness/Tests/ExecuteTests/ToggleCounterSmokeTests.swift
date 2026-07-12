import ExecuteFixture
import Testing

@Suite("ToggleCounter reproducer smoke tests")
struct ToggleCounterSmokeTests {
    // MARK: - Fault T (odd parity at depth)

    @Test("Fault T fires on a checkpoint after 25 toggles (registry minimal)")
    func faultTMinimal() {
        var counter = ToggleCounter()
        for _ in 0 ..< 25 {
            counter.toggle()
        }
        counter.checkpoint()
        #expect(counter.isCorrupted, "25 toggles are above the threshold and odd")
    }

    @Test("Fault T does not fire at the even threshold count (strict prefix)")
    func faultTEvenCountSafe() {
        var counter = ToggleCounter()
        for _ in 0 ..< 24 {
            counter.toggle()
        }
        counter.checkpoint()
        #expect(counter.isCorrupted == false, "24 toggles meet the threshold but parity is even")
    }

    @Test("Fault T does not fire below the threshold with odd parity")
    func faultTBelowThresholdSafe() {
        var counter = ToggleCounter()
        for _ in 0 ..< 23 {
            counter.toggle()
        }
        counter.checkpoint()
        #expect(counter.isCorrupted == false, "23 toggles are odd but below the threshold")
    }

    @Test("Fault T does not fire without a checkpoint")
    func faultTNeedsCheckpoint() {
        var counter = ToggleCounter()
        for _ in 0 ..< 31 {
            counter.toggle()
        }
        #expect(counter.isCorrupted == false, "the parity violation must be observed by a checkpoint")
    }

    @Test("Padding does not disturb the toggle count")
    func padDoesNotDisturbCount() {
        var counter = ToggleCounter()
        for _ in 0 ..< 25 {
            counter.toggle()
        }
        counter.pad(5)
        counter.checkpoint()
        #expect(counter.isCorrupted, "pad advances nothing; the checkpoint still observes 25 odd toggles")
    }
}
