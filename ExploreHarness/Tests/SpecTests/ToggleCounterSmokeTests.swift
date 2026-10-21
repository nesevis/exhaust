import SpecFixture
import Testing

@Suite("ToggleCounter reproducer smoke tests")
struct ToggleCounterSmokeTests {
    // MARK: - Fault T (odd parity at depth)

    @Test("Only an observed odd count at the depth threshold corrupts", arguments: [23, 24, 25, 31], [false, true])
    func checkpointContract(count: Int, padded: Bool) {
        var counter = ToggleCounter()
        for _ in 0 ..< count {
            counter.toggle()
        }
        if padded {
            counter.pad(5)
        }
        #expect(counter.isCorrupted == false)
        counter.checkpoint()
        #expect(counter.isCorrupted == (count >= 24 && count % 2 == 1))
    }
}
