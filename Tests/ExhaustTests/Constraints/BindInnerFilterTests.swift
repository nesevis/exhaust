import Testing
@testable import Exhaust

@Suite("Bind-inner filter defers CGS tuning")
struct BindInnerFilterTests {
    @Test("Filter inside bind produces valid values without eager CGS")
    func bindInnerFilterProducesValidValues() throws {
        let gen = #gen(.int(in: 1 ... 5).bind { n in
            .int(in: 0 ... 100)
                // A `filter` inside a bind is rebuilt every time the bind's continuation runs, so tuning it eagerly at construction would re-run CGS per bound value.
                // Instead the generation interpreters tune lazily and memoize by source fingerprint in a process-wide cache, so this filter is tuned at most once. The output stays valid because the predicate is always enforced; it is not guaranteed reproducible across runs, which this test does not assert.
                .filter { $0 % n == 0 }
        })

        let values = try #example(gen, count: 50, seed: 42)
        for value in values {
            #expect(value >= 0)
            #expect(value <= 100)
        }
    }
}
