import Testing
@testable import Exhaust

@Suite("Dedupe property tests")
struct DedupePropertyTests {
    @Test("Dedupe preserves all distinct elements")
    func dedupePreservesDistinctElements() {
        let generator = #gen(.int().array(length: 0...20))

        #exhaust(
            generator,
            .logging(.debug),
            .suppress(.issueReporting),
//            .randomOnly,
            .budget(.exorbitant),
            .reflecting([3, 7, 7, 0, 7, 1, 1, 4])
        ) { xs in
            #expect(Set(dedupe(xs)) == Set(xs))
        }
    }
}

// MARK: - Helpers

func dedupe<Element: Equatable>(_ array: [Element]) -> [Element] {
    array.reduce(into: [Element]()) { deduped, element in
        if let last = deduped.last, last == element {
            deduped.removeLast()
        } else {
            deduped.append(element)
        }
    }
    
}
