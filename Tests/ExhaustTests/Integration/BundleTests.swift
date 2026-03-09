import Testing
import Exhaust

@Suite("Bundle tests")
struct BundleTests {
    @Test("Add and draw returns stored elements")
    func addAndDraw() {
        let bundle = Bundle<Int>()
        bundle.add(10)
        bundle.add(20)
        bundle.add(30)

        #expect(bundle.count == 3)
        #expect(bundle.draw(at: 0) == 10)
        #expect(bundle.draw(at: 1) == 20)
        #expect(bundle.draw(at: 2) == 30)
    }

    @Test("Draw wraps around with modular indexing")
    func drawWrapsAround() {
        let bundle = Bundle<String>()
        bundle.add("a")
        bundle.add("b")

        #expect(bundle.draw(at: 5) == bundle.draw(at: 1))
    }

    @Test("Draw returns nil when empty")
    func drawReturnsNilWhenEmpty() {
        let bundle = Bundle<Int>()
        #expect(bundle.draw(at: 0) == nil)
    }

    @Test("Consume removes the element")
    func consumeRemoves() {
        let bundle = Bundle<Int>()
        bundle.add(10)
        bundle.add(20)

        let consumed = bundle.consume(at: 0)
        #expect(consumed == 10)
        #expect(bundle.count == 1)
        #expect(bundle.draw(at: 0) == 20)
    }

    @Test("Consume returns nil when empty")
    func consumeReturnsNilWhenEmpty() {
        let bundle = Bundle<Int>()
        #expect(bundle.consume(at: 0) == nil)
    }

    @Test("Reset clears all elements")
    func resetClears() {
        let bundle = Bundle<Int>()
        bundle.add(1)
        bundle.add(2)
        bundle.reset()

        #expect(bundle.isEmpty)
        #expect(bundle.isEmpty)
    }
}
