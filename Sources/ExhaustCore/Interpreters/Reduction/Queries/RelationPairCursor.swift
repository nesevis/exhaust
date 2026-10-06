/// Indexes stalled magnitudes and merges only matching small-ratio buckets in the eager query's positional order.
///
/// Every eligible pair has a unique coprime numerator and denominator bounded by ``RelationQuery/ratioCap``. For each first magnitude, dividing by a possible numerator gives its scale; multiplying that scale by the denominator identifies a same-tag bucket directly. Each matching bucket contributes one pending second index, so duplicate magnitudes never materialize a cross product. The index is tied to the values and convergence records at preparation and must be discarded when those change.
///
/// - Complexity: O(V + L log L) index preparation, O(L · R · log L + K log R) enumeration, and O(L + R) retained state, where L is the stalled leaf count, R is the fixed set of capped coprime ratios, and K is the number of emitted pairs. Dictionary lookups are expected O(1); the binary search starts each matching bucket after the first leaf.
struct RelationPairCursor {
    private struct Leaf {
        let entry: LeafEntry
        let position: Int
        let typeTag: TypeTag
        let magnitude: UInt64
    }

    private struct MagnitudeKey: Hashable {
        let typeTag: TypeTag
        let magnitude: UInt64
    }

    private struct Ratio {
        let numerator: UInt64
        let denominator: UInt64
    }

    /// Reverses positional comparison because the shared queue emits its greatest entry first. Different magnitude buckets cannot share a second index.
    private struct Row: Comparable {
        let secondIndices: [Int]
        var offset: Int
        let ratio: Ratio
        let scale: UInt64

        var secondIndex: Int {
            secondIndices[offset]
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.secondIndex > rhs.secondIndex
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.secondIndex == rhs.secondIndex
        }
    }

    /// Reduced components make a target magnitude unique for any fixed first magnitude, avoiding duplicate bucket rows.
    private static let ratios: [Ratio] = (1 ... RelationQuery.ratioCap).flatMap { numerator in
        (1 ... RelationQuery.ratioCap).compactMap { denominator in
            guard numerator != denominator, greatestCommonDivisor(numerator, denominator) == 1 else {
                return nil
            }
            return Ratio(numerator: numerator, denominator: denominator)
        }
    }

    private let leaves: [Leaf]
    private let buckets: [MagnitudeKey: [Int]]
    private var firstIndex = 0
    private var isCurrentRowPrepared = false
    private var pendingRows = ScopePriorityQueue<Row>()

    var preparedLeafCount: Int {
        leaves.count
    }

    /// Counts indexed magnitude probes independently of matches, allowing sparse and equal-value workloads to pin discovery's linear bound.
    private(set) var magnitudeLookupCount = 0

    /// Captures only eligible leaf metadata, leaving the mutable graph node buffer unowned by the cursor.
    init(graph: ChoiceGraph) {
        leaves = graph.liveNodeIDs.compactMap { nodeID -> Leaf? in
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind,
                  node.scopeAnnotation.isDepthControl == false,
                  node.scopeAnnotation.isLaneControl == false,
                  node.scopeAnnotation.isBindInner == false,
                  metadata.typeTag.isFloatingPoint == false,
                  let range = node.positionRange,
                  metadata.value.bitPattern64 != metadata.value.reductionTarget(in: metadata.validRange),
                  metadata.value.bitPattern64 > metadata.value.semanticSimplest.bitPattern64,
                  let record = graph.convergenceStore[nodeID],
                  record.bound == metadata.value.bitPattern64
            else {
                return nil
            }
            return Leaf(
                entry: LeafEntry(nodeID: nodeID, mayReshapeOnAcceptance: node.scopeAnnotation.isBindInner, bindDepth: node.scopeAnnotation.controllingBindDepth),
                position: range.lowerBound,
                typeTag: metadata.typeTag,
                magnitude: metadata.value.bitPattern64 - metadata.value.semanticSimplest.bitPattern64
            )
        }.sorted { $0.position < $1.position }
        var indexed: [MagnitudeKey: [Int]] = [:]
        for (index, leaf) in leaves.enumerated() {
            indexed[MagnitudeKey(typeTag: leaf.typeTag, magnitude: leaf.magnitude), default: []].append(index)
        }
        buckets = indexed
    }

    /// Seeds at most one row per ratio; overflow means no representable second magnitude can satisfy that ratio.
    private mutating func prepareRows() {
        let first = leaves[firstIndex]
        for ratio in Self.ratios {
            guard first.magnitude.isMultiple(of: ratio.numerator) else {
                continue
            }
            let scale = first.magnitude / ratio.numerator
            guard scale >= 2 else {
                continue
            }
            let (magnitude, overflow) = scale.multipliedReportingOverflow(by: ratio.denominator)
            guard overflow == false else {
                continue
            }
            magnitudeLookupCount += 1
            guard let secondIndices = buckets[MagnitudeKey(typeTag: first.typeTag, magnitude: magnitude)] else {
                continue
            }
            let offset = Self.firstLaterOffset(in: secondIndices, after: firstIndex)
            guard offset < secondIndices.count else {
                continue
            }
            pendingRows.insert(Row(secondIndices: secondIndices, offset: offset, ratio: ratio, scale: scale))
        }
        isCurrentRowPrepared = true
    }

    /// Skips earlier occurrences without rescanning a duplicate-magnitude bucket for each first leaf.
    private static func firstLaterOffset(in indices: [Int], after firstIndex: Int) -> Int {
        var lowerBound = 0
        var upperBound = indices.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if indices[middle] <= firstIndex {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private static func greatestCommonDivisor(_ first: UInt64, _ second: UInt64) -> UInt64 {
        var firstRemainder = first
        var secondRemainder = second
        while secondRemainder != 0 {
            (firstRemainder, secondRemainder) = (secondRemainder, firstRemainder % secondRemainder)
        }
        return firstRemainder
    }
}

extension RelationPairCursor: ScopeCursor {
    mutating func next(lastAccepted _: Bool) -> RelationPair? {
        while firstIndex + 1 < leaves.count {
            if isCurrentRowPrepared == false {
                prepareRows()
            }
            guard var row = pendingRows.popFirst() else {
                firstIndex += 1
                isCurrentRowPrepared = false
                continue
            }
            let pair = RelationPair(
                first: leaves[firstIndex].entry,
                second: leaves[row.secondIndex].entry,
                numerator: row.ratio.numerator,
                denominator: row.ratio.denominator,
                scale: row.scale
            )
            row.offset += 1
            if row.offset < row.secondIndices.count {
                pendingRows.insert(row)
            }
            return pair
        }
        return nil
    }
}
