import Exhaust
import Testing

@Suite("Dedupe property tests")
struct DedupePropertyTests {
    @Test("Dedupe preserves all distinct elements")
    func dedupePreservesAllDistinctElements() {
        let generator = #gen(.int().array(length: 0 ... 20))

        let counterexample = #exhaust(
            generator,
            reflecting: [3, 7, 7, 0, 7, 1, 1, 4],
            .suppress(.issueReporting),
            .budget(.extensive)
        ) { xs in
            #expect(Set(dedupe(xs)) == Set(xs))
        }

        #expect(counterexample == [0, 0])
    }
}

// MARK: - Helpers

/// Removes adjacent duplicate elements, dropping both members of an equal pair.
///
/// The defect is deliberate. An adjacent equal pair leaves no element behind, so `Set(dedupe(xs)) != Set(xs)` whenever the array contains one. The smallest such array is `[0, 0]`.
func dedupe<Element: Equatable>(_ array: [Element]) -> [Element] {
    array.reduce(into: [Element]()) { deduped, element in
        if let last = deduped.last, last == element {
            deduped.removeLast()
        } else {
            deduped.append(element)
        }
    }
}
