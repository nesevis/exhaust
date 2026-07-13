import ExecuteFixture
import Testing

@Suite("CoupledStore reproducer smoke tests")
struct CoupledStoreSmokeTests {
    // MARK: - Fault C (probe matches a key set at least three commands earlier)

    @Test("Fault C fires when the probe matches a key three commands old (registry minimal)")
    func faultCMinimal() {
        var store = CoupledStore()
        store.setKey(11)
        store.pad(0)
        store.pad(0)
        store.pad(0)
        store.probe(11)
        #expect(store.isCorrupted, "a matching probe at distance 4 should fire fault C")
    }

    @Test("Fault C fires at exactly the threshold distance")
    func faultCExactDistance() {
        var store = CoupledStore()
        store.setKey(4)
        store.pad(0)
        store.pad(0)
        store.probe(4)
        #expect(store.isCorrupted, "the probe lands 3 commands after setKey — exactly the threshold")
    }

    @Test("Fault C does not fire when the probe is too young (strict prefix)")
    func faultCYoungProbeSafe() {
        var store = CoupledStore()
        store.setKey(4)
        store.pad(0)
        store.probe(4)
        #expect(store.isCorrupted == false, "distance 2 is below the threshold")
    }

    @Test("Fault C does not fire on a mismatched probe")
    func faultCMismatchSafe() {
        var store = CoupledStore()
        store.setKey(4)
        store.pad(0)
        store.pad(0)
        store.pad(0)
        store.probe(5)
        #expect(store.isCorrupted == false, "the probe argument must equal the stored key")
    }

    @Test("A later setKey restarts the distance clock")
    func laterSetKeyRestartsClock() {
        var store = CoupledStore()
        store.setKey(4)
        store.pad(0)
        store.pad(0)
        store.setKey(4)
        store.probe(4)
        #expect(store.isCorrupted == false, "the second setKey is only one command before the probe")
    }

    @Test("A probe before any setKey is a legal no-op")
    func probeBeforeSetKeySafe() {
        var store = CoupledStore()
        store.probe(0)
        store.pad(0)
        store.probe(15)
        #expect(store.isCorrupted == false, "no key is stored; the sentinel never matches the 0...15 domain")
    }
}
