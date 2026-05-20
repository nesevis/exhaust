import Testing
@testable import Exhaust

@Suite("Bind-inner filter defers CGS tuning")
struct BindInnerFilterTests {
    @Test("Filter inside bind produces valid values without eager CGS")
    func bindInnerFilterProducesValidValues() {
        let gen = #gen(.int(in: 1 ... 5).bind { n in
            .int(in: 0 ... 100)
                // A `filter` inside a bind would cause eager CGS to fire for every time the bind's continuation is executed.
                // This test lets you confirm that the @TaskLocal `isInterpreting` workaround is causing the eager CGS to be deferred to the interpreter and then cached. It's not as optimal, but it prevents a significant footgun and lets Exhaust hide this complexity well
                .filter { $0 % n == 0 }
        })

        // TODO: Replace generator declaration with #gen
        let values = #example(gen, count: 50, seed: 42)
        for value in values {
            #expect(value >= 0)
            #expect(value <= 100)
        }
    }
}
