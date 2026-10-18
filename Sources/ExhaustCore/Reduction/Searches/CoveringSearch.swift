//
//  CoveringSearch.swift
//  Exhaust
//

// MARK: - Covering Search

/// Searches a lifted bound subtree for any failing assignment of its leaves.
///
/// A composition's downstream needs to discover failures in the lifted bound subtree, not minimize toward a known target, so it covers the value space instead of moving each leaf toward its simplest value. Only the leaves' own entries vary: entries between them, such as a nested bind's controller the scope leaves out, stay fixed.
struct CoveringSearch: ReductionSearch {
    private var search: CoveringRows
    private var hasSearch = false

    /// Covers the entries at `leaves`' positions in `baseSequence`, skipping leaves without a position or a value entry.
    init(
        leaves: [LeafEntry],
        graph: ChoiceGraph,
        baseSequence: ChoiceSequence,
        tuning: ReductionTuning,
        rowCache: CoveringRowCache
    ) {
        search = CoveringRows(tuning: tuning, rowCache: rowCache)
        var positions: [Int] = []
        var validEntries: [LeafEntry] = []
        for entry in leaves {
            guard entry.nodeID < graph.nodes.count,
                  let range = graph.nodes[entry.nodeID].positionRange,
                  range.lowerBound < baseSequence.count,
                  baseSequence[range.lowerBound].value != nil
            else {
                continue
            }
            positions.append(range.lowerBound)
            validEntries.append(entry)
        }
        guard validEntries.isEmpty == false else {
            return
        }

        // Ascending, so covering rows assign values in sequence order.
        search.start(sequence: baseSequence, positions: positions.sorted())
        hasSearch = true
    }

    /// Covers every value entry in `positionRange` of `sequence`, up to ``ReductionTuning/maxCoveredPositions``.
    init(
        sequence: ChoiceSequence,
        positionRange: ClosedRange<Int>,
        tuning: ReductionTuning,
        rowCache: CoveringRowCache
    ) {
        search = CoveringRows(tuning: tuning, rowCache: rowCache)
        search.start(sequence: sequence, positionRange: positionRange)
        hasSearch = true
    }

    mutating func next(_ feedback: SearchFeedback, into buffer: inout ChoiceSequence) -> ReductionCandidate? {
        guard hasSearch else {
            return nil
        }
        guard let built = search.nextProbe(lastAccepted: feedback.isAccepted) else {
            return nil
        }
        // The composition replaces this mutation with the upstream's reshape mutation, so the empty leafValues is a placeholder; the candidate carries the downstream values.
        buffer = built
        return .written(mutation: .leafValues([]), admission: .standard)
    }
}

// MARK: - Covering Rows

/// Enumerates value assignments over a set of sequence positions.
///
/// Only the first ``ReductionTuning/maxCoveredPositions`` value positions are searched; the rest keep their base values. Three regimes based on the searched positions' total domain size:
/// - **Small domains** (total space ≤ ``ReductionTuning/coveringExhaustiveThreshold``): exhaustive enumeration of all value assignments via mixed-radix counting. Each coordinate visits its values simplest first, nearest its reduction target and below before above at equal distance, so for a signed leaf 0, −1, 1, −2, and so on. Floating-point leaves keep bit-pattern order. Under ``AcceptancePolicy/stop`` the first failing row is the one committed, so this order makes it the simplest assignment the regime reaches.
/// - **Large domains, two or more parameters**: pairwise covering (strength 2) via ``BalancedCoveringArrayGenerator`` over each leaf's ``CoveringRepresentatives``, one greedy row per call, with no upfront batch build. Within ``ReductionTuning/coveringBudget`` rows, every combination of two leaves' representatives can be tried.
/// - **Large domain, one parameter**: the ends of the range, alternating lowest and highest and working inward, up to ``ReductionTuning/coveringBudget`` rows. Pairwise covering needs two parameters, and a range that a lift has just widened fails at its edges when it fails at all: the values the previous configuration could not express are the ones farthest from where it sat.
struct CoveringRows {
    private let exhaustiveThreshold: UInt64
    private let coveringBudget: Int
    private let maxCoveredPositions: Int

    // MARK: - State

    private var baseSequence: ChoiceSequence = .init([])
    private var valuePositions: [ValuePosition] = []

    /// Prebuilt rows for the exhaustive and range-end regimes. Empty in the pairwise regime.
    private var exhaustiveProbes: [CoveringArrayRow] = []
    private var exhaustiveProbeIndex = 0
    /// Whether row values index each coordinate's values simplest first rather than from the domain's lower end. Set in the exhaustive regime only.
    private var ordersBySimplicity = false

    /// Shared pairwise row streams, one per shape.
    private let rowCache: CoveringRowCache
    /// The pairwise rows for this pass's shape, read from ``rowCache``. Nil in the exhaustive and range-end regimes.
    private var pairwiseRows: CoveringRowCache.Stream?
    private var pullProbeCount = 0
    /// Each leaf's representative offsets in the pairwise regime, which the generator's row values index into.
    private var representativeOffsets: [[UInt64]] = []

    /// Reads ``ReductionTuning/coveringExhaustiveThreshold``, ``ReductionTuning/coveringBudget``, and ``ReductionTuning/maxCoveredPositions``.
    init(tuning: ReductionTuning, rowCache: CoveringRowCache) {
        exhaustiveThreshold = tuning.coveringExhaustiveThreshold
        coveringBudget = tuning.coveringBudget
        maxCoveredPositions = tuning.maxCoveredPositions
        self.rowCache = rowCache
    }

    private struct ValuePosition {
        let index: Int
        let domainLower: UInt64
        let domainSize: UInt64
        /// The reduction target's offset from ``domainLower``.
        let targetOffset: UInt64
        let tag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
    }

    /// Starts a pass over the value entries in `positionRange`, up to ``ReductionTuning/maxCoveredPositions``.
    mutating func start(sequence: ChoiceSequence, positionRange: ClosedRange<Int>) {
        begin(
            sequence: sequence,
            valuePositions: collectValuePositions(in: positionRange, from: sequence)
        )
    }

    /// Starts a pass over the value entries at `positions` only, in the order given. Every other entry stays fixed, which a spanning range does not guarantee: a bound value scope can leave out a nested bind's controller that sits between two of its leaves.
    mutating func start(sequence: ChoiceSequence, positions: [Int]) {
        var collected: [ValuePosition] = []
        for index in positions {
            guard collected.count < maxCoveredPositions else {
                break
            }
            guard let position = valuePosition(at: index, in: sequence) else {
                continue
            }
            collected.append(position)
        }
        begin(sequence: sequence, valuePositions: collected)
    }

    private mutating func begin(
        sequence: ChoiceSequence,
        valuePositions: [ValuePosition]
    ) {
        baseSequence = sequence
        self.valuePositions = valuePositions
        exhaustiveProbeIndex = 0
        exhaustiveProbes = []
        ordersBySimplicity = false
        pairwiseRows = nil
        pullProbeCount = 0
        representativeOffsets = []

        guard valuePositions.isEmpty == false else {
            return
        }

        let totalSpace = computeTotalSpace(valuePositions)

        if totalSpace <= exhaustiveThreshold {
            exhaustiveProbes = buildExhaustiveRows(count: Int(totalSpace))
            ordersBySimplicity = true
        } else if valuePositions.count == 1 {
            exhaustiveProbes = buildRangeEndRows(domainSize: totalSpace)
        } else {
            // Pull-based pairwise coverage over each leaf's representatives. Rows are generated lazily in nextProbe().
            let perLeafCount = CoveringRepresentatives.perLeafCount(rowBudget: coveringBudget)
            representativeOffsets = valuePositions.map {
                CoveringRepresentatives.offsets(domainSize: $0.domainSize, count: perLeafCount)
            }
            pairwiseRows = rowCache.stream(forDomainSizes: representativeOffsets.map { UInt64($0.count) })
        }
    }

    /// The next assignment written over the base sequence, or nil when the regime is exhausted.
    mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        let row: CoveringArrayRow?

        if let pairwiseRows {
            guard pullProbeCount < coveringBudget else {
                return nil
            }
            row = pairwiseRows.row(at: pullProbeCount)
            if row != nil {
                pullProbeCount += 1
            }
        } else {
            guard exhaustiveProbeIndex < exhaustiveProbes.count else {
                return nil
            }
            row = exhaustiveProbes[exhaustiveProbeIndex]
            exhaustiveProbeIndex += 1
        }

        guard let row else {
            return nil
        }

        var candidate = baseSequence
        var offset = 0
        while offset < valuePositions.count {
            guard offset < row.values.count else {
                break
            }
            let position = valuePositions[offset]
            let rowValue = representativeOffsets.isEmpty
                ? row.values[offset]
                : representativeOffsets[offset][Int(row.values[offset])]
            let valueIndex = switch ordersBySimplicity && position.tag.isFloatingPoint == false {
                case true:
                    Self.offset(simplicityRank: rowValue, targetOffset: position.targetOffset, domainSize: position.domainSize)
                case false:
                    rowValue
            }
            // A full-width leaf's highest index overflows a nonzero lower bound. Clamp to the domain's top.
            let (sum, overflowed) = position.domainLower.addingReportingOverflow(valueIndex)
            let bitPattern = overflowed ? UInt64.max : sum

            candidate[position.index] = .value(.init(
                choice: ChoiceValue(
                    position.tag.makeConvertible(bitPattern64: bitPattern),
                    tag: position.tag
                ),
                validRange: position.validRange,
                isRangeExplicit: position.isRangeExplicit
            ))
            offset += 1
        }

        return candidate
    }

    // MARK: - Private Helpers

    private func collectValuePositions(
        in range: ClosedRange<Int>,
        from sequence: ChoiceSequence
    ) -> [ValuePosition] {
        var positions: [ValuePosition] = []
        for index in range {
            guard index < sequence.count, positions.count < maxCoveredPositions else {
                break
            }
            guard let position = valuePosition(at: index, in: sequence) else {
                continue
            }
            positions.append(position)
        }
        return positions
    }

    /// The ranged value entry at `index`, or nil when the index is outside the sequence or the entry is not a value with a valid range.
    private func valuePosition(at index: Int, in sequence: ChoiceSequence) -> ValuePosition? {
        guard index < sequence.count,
              let value = sequence[index].value,
              let validRange = value.validRange
        else {
            return nil
        }
        let target = value.choice.reductionTarget(in: validRange)
        let targetOffset: UInt64 = switch validRange.contains(target) {
            case true:
                target - validRange.lowerBound
            case false:
                0
        }
        return ValuePosition(
            index: index,
            domainLower: validRange.lowerBound,
            domainSize: validRange.saturatingCount,
            targetOffset: targetOffset,
            tag: value.choice.tag,
            validRange: validRange,
            isRangeExplicit: value.isRangeExplicit
        )
    }

    private func computeTotalSpace(_ positions: [ValuePosition]) -> UInt64 {
        var product: UInt64 = 1
        for position in positions {
            let (result, overflow) = product.multipliedReportingOverflow(by: position.domainSize)
            if overflow || result > UInt64.max / 2 {
                return UInt64.max
            }
            product = result
        }
        return product
    }

    /// Builds rows for a single parameter whose domain exceeds the exhaustive threshold: the lowest value, the highest, the second lowest, the second highest, and so on, until ``ReductionTuning/coveringBudget`` rows or the ends meet.
    private func buildRangeEndRows(domainSize: UInt64) -> [CoveringArrayRow] {
        var rows: [CoveringArrayRow] = []
        rows.reserveCapacity(coveringBudget)
        var step: UInt64 = 0
        while rows.count < coveringBudget {
            let low = step
            let high = domainSize &- 1 &- step
            guard low <= high else {
                break
            }
            rows.append(CoveringArrayRow(values: [low]))
            if high != low, rows.count < coveringBudget {
                rows.append(CoveringArrayRow(values: [high]))
            }
            step &+= 1
        }
        return rows
    }

    /// The domain offset of the value at `rank` in simplicity order: the target first, then alternately one step below and one step above, continuing on the longer side once the shorter one is used up.
    private static func offset(simplicityRank rank: UInt64, targetOffset: UInt64, domainSize: UInt64) -> UInt64 {
        guard rank > 0 else {
            return targetOffset
        }
        let below = targetOffset
        let above = domainSize - 1 - targetOffset
        let alternating = min(below, above)
        guard rank > 2 * alternating else {
            let distance = (rank + 1) / 2
            return Self.offset(targetOffset, movedBy: distance, below: rank % 2 == 1)
        }
        let distance = alternating + (rank - 2 * alternating)
        return Self.offset(targetOffset, movedBy: distance, below: below > above)
    }

    private static func offset(_ targetOffset: UInt64, movedBy distance: UInt64, below: Bool) -> UInt64 {
        switch below {
            case true:
                targetOffset - distance
            case false:
                targetOffset + distance
        }
    }

    /// Builds exhaustive rows with the leftmost coordinate changing slowest. Row values are simplicity ranks, which ``nextProbe(lastAccepted:)`` maps to domain offsets.
    private func buildExhaustiveRows(count: Int) -> [CoveringArrayRow] {
        var rows: [CoveringArrayRow] = []
        rows.reserveCapacity(count)
        for combinationIndex in 0 ..< count {
            var values = [UInt64](repeating: 0, count: valuePositions.count)
            var remaining = combinationIndex
            for offset in (0 ..< valuePositions.count).reversed() {
                let domainSize = Int(valuePositions[offset].domainSize)
                values[offset] = UInt64(remaining % domainSize)
                remaining /= domainSize
            }
            rows.append(CoveringArrayRow(values: values))
        }
        return rows
    }
}

// MARK: - Row Cache

/// Pairwise covering rows by shape, shared by every covering search in one reduction run.
///
/// A ``BalancedCoveringArrayGenerator`` row depends only on the domain sizes it was created with, because the reducer always uses seed zero and the default tracking threshold. Covering searches recur with few distinct shapes, so each shape's rows are generated once and replayed: every search reads the same rows, in the same order, that a generator of its own would have produced.
///
/// A class, so the passes of one run share it through ``EncoderInput``. One run uses it from one thread.
final class CoveringRowCache {
    /// One shape's rows, generated on demand and kept.
    final class Stream {
        private let generator: BalancedCoveringArrayGenerator
        private var rows: [CoveringArrayRow] = []
        private var isExhausted = false

        init(domainSizes: [UInt64]) {
            generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)
        }

        /// The row at `index`, generating rows up to it if no search has reached it yet, or nil when the generator ends first.
        func row(at index: Int) -> CoveringArrayRow? {
            while rows.count <= index, isExhausted == false {
                guard let row = generator.next() else {
                    isExhausted = true
                    break
                }
                rows.append(row)
            }
            guard index < rows.count else {
                return nil
            }
            return rows[index]
        }
    }

    private var streams: [[UInt64]: Stream] = [:]

    /// The shared stream for `domainSizes`, created on first request.
    func stream(forDomainSizes domainSizes: [UInt64]) -> Stream {
        if let stream = streams[domainSizes] {
            return stream
        }
        let stream = Stream(domainSizes: domainSizes)
        streams[domainSizes] = stream
        return stream
    }
}
