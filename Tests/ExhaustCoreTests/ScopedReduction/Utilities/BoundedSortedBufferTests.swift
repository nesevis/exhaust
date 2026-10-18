import Testing
@testable import ExhaustCore

@Suite("Bounded sorted buffer")
struct BoundedSortedBufferTests {
    @Test("Bounded sorting retains the eager stable prefix, including ties and zero limits", arguments: [0, 1, 30, 100])
    func stableBoundedSorting(limit: Int) {
        let values = (0 ..< 200).map { index in (priority: index % 11, discovery: index) }
        var buffer = BoundedSortedBuffer<(priority: Int, discovery: Int)>(limit: limit)
        for value in values {
            buffer.insert(value) { $0.priority > $1.priority }
            #expect(buffer.elements.count <= limit)
        }
        let expected = values.sorted { $0.priority > $1.priority }.prefix(limit)
        #expect(buffer.elements.map(\.discovery) == expected.map(\.discovery))
    }
}
