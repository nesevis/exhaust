/// Retains a stable sorted prefix without collecting the discarded tail.
///
/// Equivalent entries stay in insertion order. The comparison closure is nonescaping so callers can rank compact descriptors against a shared baseline without retaining it per entry.
///
/// - Complexity: O(limit) storage and O(log limit) comparisons plus O(limit) moves per insertion.
struct BoundedSortedBuffer<Element> {
    private(set) var elements: [Element] = []
    let limit: Int

    init(limit: Int) {
        self.limit = max(0, limit)
        elements.reserveCapacity(self.limit)
    }

    /// Inserts after equivalent entries and discards anything beyond the requested prefix.
    mutating func insert(_ element: Element, precedes: (Element, Element) -> Bool) {
        var lowerBound = 0
        var upperBound = elements.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if precedes(element, elements[middle]) {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        guard lowerBound < limit else {
            return
        }
        elements.insert(element, at: lowerBound)
        if elements.count > limit {
            elements.removeLast()
        }
    }
}
