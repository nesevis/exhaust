//
//  RangeSet.swift
//  Exhaust
//

// MARK: - ExhaustRangeSet

/// A set of comparable values represented as sorted, non-overlapping, non-adjacent ranges backed by a `ContiguousArray`.
///
/// Ported from the Swift stdlib implementation. The SE0270 backport package uses a three-case enum storage (`empty`/`singleRange`/`variadic`) that adds switch dispatch, `unsafeBitCast`, and unique-reference bookkeeping on every access. The stdlib uses a flat `ContiguousArray<Range<Bound>>` with binary-search-based insert and merge, which the compiler can inline and vectorize without cross-module barriers.
package struct ExhaustRangeSet<Bound: Comparable> {
    var _ranges: ContiguousArray<Range<Bound>> = []

    package init() {}

    package init(_ range: Range<Bound>) {
        if range.isEmpty == false {
            _ranges = [range]
        }
    }

    package var isEmpty: Bool {
        _ranges.isEmpty
    }

    package func contains(_ value: Bound) -> Bool {
        let index = _partitioningIndex(in: _ranges) { $0.upperBound > value }
        guard index < _ranges.count else { return false }
        return _ranges[index].lowerBound <= value
    }

    // MARK: - Insert

    package mutating func insert(contentsOf range: Range<Bound>) {
        if range.isEmpty { return }
        guard _ranges.isEmpty == false else {
            _ranges.append(range)
            return
        }
        guard range.lowerBound < _ranges[_ranges.count - 1].upperBound else {
            _appendOrMerge(range)
            return
        }
        guard range.upperBound >= _ranges[0].lowerBound else {
            _ranges.insert(range, at: 0)
            return
        }

        let indices = _indicesOfRange(range, includeAdjacent: true)

        guard indices.isEmpty == false else {
            _ranges.insert(range, at: indices.lowerBound)
            return
        }

        let lower = Swift.min(_ranges[indices.lowerBound].lowerBound, range.lowerBound)
        let upper = Swift.max(_ranges[indices.upperBound - 1].upperBound, range.upperBound)
        let merged = lower ..< upper

        if indices.count == 1, merged == _ranges[indices.lowerBound] {
            return
        }
        _ranges.replaceSubrange(indices, with: CollectionOfOne(merged))
    }

    // MARK: - Remove

    package mutating func remove(contentsOf range: Range<Bound>) {
        if range.isEmpty || _ranges.isEmpty { return }
        guard range.lowerBound < _ranges[_ranges.count - 1].upperBound else { return }
        guard range.upperBound > _ranges[0].lowerBound else { return }

        let indices = _indicesOfRange(range, includeAdjacent: false)
        guard indices.isEmpty == false else { return }

        let overlapsLower = range.lowerBound > _ranges[indices.lowerBound].lowerBound
        let overlapsUpper = range.upperBound < _ranges[indices.upperBound - 1].upperBound

        switch (overlapsLower, overlapsUpper) {
            case (false, false):
                _ranges.removeSubrange(indices)
            case (false, true):
                _ranges.replaceSubrange(
                    indices,
                    with: CollectionOfOne(range.upperBound ..< _ranges[indices.upperBound - 1].upperBound)
                )
            case (true, false):
                _ranges.replaceSubrange(
                    indices,
                    with: CollectionOfOne(_ranges[indices.lowerBound].lowerBound ..< range.lowerBound)
                )
            case (true, true):
                _ranges.replaceSubrange(indices, with: _Pair(
                    _ranges[indices.lowerBound].lowerBound ..< range.lowerBound,
                    range.upperBound ..< _ranges[indices.upperBound - 1].upperBound
                ))
        }
    }

    // MARK: - Ranges View

    package var ranges: Ranges {
        Ranges(_ranges: _ranges)
    }

    package struct Ranges: RandomAccessCollection {
        var _ranges: ContiguousArray<Range<Bound>>
        package var startIndex: Int {
            0
        }

        package var endIndex: Int {
            _ranges.count
        }

        package subscript(index: Int) -> Range<Bound> {
            _ranges[index]
        }
    }

    // MARK: - Internals

    private mutating func _appendOrMerge(_ range: Range<Bound>) {
        if _ranges[_ranges.count - 1].upperBound == range.lowerBound {
            _ranges[_ranges.count - 1] = _ranges[_ranges.count - 1].lowerBound ..< range.upperBound
        } else {
            _ranges.append(range)
        }
    }

    private func _indicesOfRange(_ range: Range<Bound>, includeAdjacent: Bool) -> Range<Int> {
        let beginningIndex: Int
        if includeAdjacent {
            beginningIndex = _partitioningIndex(in: _ranges) { $0.upperBound >= range.lowerBound }
        } else {
            beginningIndex = _partitioningIndex(in: _ranges) { $0.upperBound > range.lowerBound }
        }

        let endingIndex: Int
        if includeAdjacent {
            endingIndex = _partitioningIndex(in: _ranges[beginningIndex...]) { $0.lowerBound > range.upperBound }
        } else {
            endingIndex = _partitioningIndex(in: _ranges[beginningIndex...]) { $0.lowerBound >= range.upperBound }
        }

        return beginningIndex ..< endingIndex
    }

    private func _partitioningIndex<C: RandomAccessCollection>(
        in collection: C,
        where predicate: (C.Element) -> Bool
    ) -> C.Index {
        var low = collection.startIndex
        var count = collection.count
        while count > 0 {
            let half = count / 2
            let mid = collection.index(low, offsetBy: half)
            if predicate(collection[mid]) {
                count = half
            } else {
                low = collection.index(after: mid)
                count -= half + 1
            }
        }
        return low
    }

    private func _inverted(within bounds: Range<Bound>) -> ExhaustRangeSet {
        guard _ranges.isEmpty == false else { return ExhaustRangeSet(bounds) }
        var result = ExhaustRangeSet()
        var low = bounds.lowerBound
        for range in _ranges {
            if range.lowerBound > low {
                result._ranges.append(low ..< range.lowerBound)
            }
            low = range.upperBound
        }
        if low < bounds.upperBound {
            result._ranges.append(low ..< bounds.upperBound)
        }
        return result
    }
}

// MARK: - Equatable / Hashable

extension ExhaustRangeSet: Equatable where Bound: Equatable {}

extension ExhaustRangeSet: Hashable where Bound: Hashable {
    package func hash(into hasher: inout Hasher) {
        hasher.combine(_ranges.count)
        for range in _ranges {
            hasher.combine(range)
        }
    }
}

// MARK: - removeSubranges

extension MutableCollection where Self: RangeReplaceableCollection {
    mutating func removeSubranges(_ subranges: ExhaustRangeSet<Index>) {
        guard let firstRange = subranges.ranges.first else { return }

        var endOfKept = firstRange.lowerBound
        var firstUnprocessed = firstRange.upperBound

        for range in subranges.ranges.dropFirst() {
            let nextLow = range.lowerBound
            while firstUnprocessed != nextLow {
                swapAt(endOfKept, firstUnprocessed)
                formIndex(after: &endOfKept)
                formIndex(after: &firstUnprocessed)
            }
            firstUnprocessed = range.upperBound
        }

        while firstUnprocessed != endIndex {
            swapAt(endOfKept, firstUnprocessed)
            formIndex(after: &endOfKept)
            formIndex(after: &firstUnprocessed)
        }

        removeSubrange(endOfKept ..< endIndex)
    }
}

// MARK: - Pair Helper

private struct _Pair<Element>: RandomAccessCollection {
    private let first: Element
    private let second: Element

    init(_ first: Element, _ second: Element) {
        self.first = first
        self.second = second
    }

    var startIndex: Int {
        0
    }

    var endIndex: Int {
        2
    }

    subscript(position: Int) -> Element {
        position == 0 ? first : second
    }
}
