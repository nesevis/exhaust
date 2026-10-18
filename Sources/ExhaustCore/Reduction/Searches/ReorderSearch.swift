//
//  ReorderSearch.swift
//  Exhaust
//

// MARK: - Reorder Search

/// Reorders elements within type-homogeneous sibling groups into ascending numeric order, one group per probe, deepest first.
///
/// Shortlex reduction produces counterexamples like `[0, -1, 1]` because zigzag encoding maps `-1` to shortlex key `1` and `1` to key `2`. This search reorders to `[-1, 0, 1]`, the ascending numeric order a user expects, and the property decides whether the failure survives. Groups already in natural order are skipped. Every accepted reordering requires a rebuild, which ends the pass, so every probe is built from the base sequence.
struct ReorderSearch: ReductionSearch {
    private let groups: [ReorderableGroup]
    private var groupIndex = 0
    private let baseSequence: ChoiceSequence

    init(scope: ReorderingScope, baseSequence: ChoiceSequence) {
        groups = scope.groups
        self.baseSequence = baseSequence
    }

    mutating func next(_: SearchFeedback, into buffer: inout ChoiceSequence) -> ReductionCandidate? {
        while groupIndex < groups.count {
            let group = groups[groupIndex]
            groupIndex += 1
            let ranges = group.ranges

            let keys = ranges.map {
                ChoiceSequence.siblingComparisonKey(from: baseSequence, range: $0)
            }

            // ``ReorderingQuery`` buckets siblings by outer-node ``ChoiceGraphNodeKind`` category. Container siblings can still flatten to different numeric type profiles. ``ChoiceValue`` comparisons assume matching numeric categories, so skip incompatible groups before sorting them.
            guard Self.keysAreTypeCompatible(keys) else {
                continue
            }

            let sortedIndices = keys.indices.sorted { lhs, rhs in
                Self.naturalOrderPrecedes(keys[lhs], keys[rhs])
            }
            guard sortedIndices != Array(keys.indices) else {
                continue
            }

            buffer = baseSequence.permutingSpans(
                ranges: ranges,
                permutation: sortedIndices
            )
            return .written(mutation: .sequenceReordered, admission: .standard)
        }
        return nil
    }

    // MARK: - Helpers

    /// Compares two arrays of ``ChoiceValue`` by natural numeric order.
    ///
    /// Uses ``ChoiceValue``'s `Comparable` conformance, which compares signed integers by `Int64` value, unsigned by `UInt64`, and floating-point by `Double`: the ordering a human reader expects.
    private static func naturalOrderPrecedes(
        _ lhs: [ChoiceValue],
        _ rhs: [ChoiceValue]
    ) -> Bool {
        for (left, right) in zip(lhs, rhs) {
            if left < right {
                return true
            }
            if left > right {
                return false
            }
        }
        return lhs.count < rhs.count
    }

    /// Returns `true` when every pair of keys is compatible at every overlapping position.
    ///
    /// The longest key covers every position that another pair can compare. A shorter reference would miss conflicting categories in longer siblings' suffixes. Matching numeric categories permit different bit widths within a category and different key lengths; mismatched categories can compare decoded values against zero or unrelated bit patterns.
    ///
    /// - Complexity: O(*k* + *v*), where *k* is the number of keys and *v* is their total value count.
    private static func keysAreTypeCompatible(_ keys: [[ChoiceValue]]) -> Bool {
        guard let longest = keys.max(by: { $0.count < $1.count }) else {
            return true
        }
        for key in keys {
            for (reference, value) in zip(longest, key) {
                guard categoryRank(reference.tag) == categoryRank(value.tag) else {
                    return false
                }
            }
        }
        return true
    }

    private static func categoryRank(_ tag: TypeTag) -> Int {
        if tag.isFloatingPoint {
            return 2
        }
        if tag.isSigned {
            return 1
        }
        return 0
    }
}
