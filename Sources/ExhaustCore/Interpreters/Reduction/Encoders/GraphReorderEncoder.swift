//
//  GraphReorderEncoder.swift
//  Exhaust
//

/// Reorders elements within type-homogeneous sibling groups into ascending numeric order.
///
/// Shortlex reduction produces counterexamples like `[0, -1, 1]` because zigzag encoding maps `-1` to shortlex key `1` and `1` to key `2`. This encoder reorders to `[-1, 0, 1]` — the ascending numeric order a user expects — and validates that the property still fails.
///
/// Runs as a final pass after the main graph reduction loop. Receives a pre-filtered ``ReorderingScope`` from ``ReorderingQuery`` and emits one probe per eligible group, deepest-first. On acceptance, ``refreshState(graph:sequence:)`` updates the internal sequence so subsequent groups operate on the latest accepted state.
struct GraphReorderEncoder: GraphEncoder {
    let name: EncoderName = .numericReorder

    private var groups: [ReorderableGroup] = []
    private var groupIndex: Int = 0
    private var currentSequence: ChoiceSequence = []

    mutating func start(scope: EncoderInput) {
        guard case let .reorder(reorderScope) = scope.transformation.operation else {
            groups = []
            groupIndex = 0
            return
        }
        groups = reorderScope.groups
        groupIndex = 0
        currentSequence = scope.baseSequence
    }

    /// Emits the next group's reordering probe or `nil` when all groups have been attempted.
    ///
    /// Skips groups that are already in natural order. The `lastAccepted` parameter is intentionally ignored: ``refreshState(graph:sequence:)`` delivers the updated sequence after every accepted probe, keeping ``currentSequence`` in sync without needing to re-examine the acceptance flag here.
    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted _: Bool) -> EncoderProbe? {
        while groupIndex < groups.count {
            let group = groups[groupIndex]
            groupIndex += 1
            let ranges = group.ranges

            // Re-extract keys from the current sequence so subsequent groups see the arrangement settled by earlier accepted reorderings.
            let keys = ranges.map {
                ChoiceSequence.siblingComparisonKey(from: currentSequence, range: $0)
            }

            // ``ReorderingQuery`` buckets siblings by outer-node ``ChoiceGraphNodeKind`` category. Container siblings can still flatten to different numeric type profiles. ``ChoiceValue`` comparisons assume matching numeric categories, so skip incompatible groups before sorting them.
            guard keysAreTypeCompatible(keys) else {
                continue
            }

            let sortedIndices = keys.indices.sorted { lhs, rhs in
                naturalOrderPrecedes(keys[lhs], keys[rhs])
            }
            guard sortedIndices != Array(keys.indices) else {
                continue
            }

            candidate = currentSequence.permutingSpans(
                ranges: ranges,
                permutation: sortedIndices
            )

            return .sequenceReordered
        }
        return nil
    }
}

// MARK: - Private Helpers

/// Compares two arrays of ``ChoiceValue`` by natural numeric order.
///
/// Uses ``ChoiceValue``'s `Comparable` conformance which compares signed integers by `Int64` value, unsigned by `UInt64`, and floating-point by `Double` — the ordering a human reader expects.
private func naturalOrderPrecedes(
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
private func keysAreTypeCompatible(_ keys: [[ChoiceValue]]) -> Bool {
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

private func categoryRank(_ tag: TypeTag) -> Int {
    if tag.isFloatingPoint {
        return 2
    }
    if tag.isSigned {
        return 1
    }
    return 0
}
