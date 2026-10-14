//
//  ScopedCoveringSearch.swift
//  Exhaust
//

// MARK: - Covering Search

/// Searches a lifted bound subtree for any failing assignment of its leaves.
///
/// A composition's downstream needs to discover failures in the lifted bound subtree, not minimize toward a known target, so it covers the value space instead of moving each leaf toward its simplest value. Only the leaves' own entries vary: entries between them, such as a nested bind's controller the scope leaves out, stay fixed.
struct ScopedCoveringSearch: ScopedSearch {
    private var search: ScopedCoveringRows
    private var hasSearch = false

    /// Covers the entries at `leaves`' positions in `baseSequence`, skipping leaves without a position or a value entry.
    init(leaves: [LeafEntry], graph: ChoiceGraph, baseSequence: ChoiceSequence, tuning: ScopedReductionTuning) {
        search = ScopedCoveringRows(tuning: tuning)
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

    /// Covers every value entry in `positionRange` of `sequence`, up to ``ScopedReductionTuning/maxCoveredPositions``.
    init(sequence: ChoiceSequence, positionRange: ClosedRange<Int>, tuning: ScopedReductionTuning) {
        search = ScopedCoveringRows(tuning: tuning)
        search.start(sequence: sequence, positionRange: positionRange)
        hasSearch = true
    }

    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
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

// MARK: - Covering Search

/// Enumerates value assignments over a set of sequence positions.
///
/// Only the first ``ScopedReductionTuning/maxCoveredPositions`` value positions are searched; the rest keep their base values. Three regimes based on the searched positions' total domain size:
/// - **Small domains** (total space ≤ ``ScopedReductionTuning/coveringExhaustiveThreshold``): exhaustive enumeration of all value assignments via mixed-radix counting.
/// - **Large domains, two or more parameters**: pairwise covering (strength 2) via ``BalancedCoveringArrayGenerator`` over each leaf's ``CoveringRepresentatives``, one greedy row per call, with no upfront batch build. Within ``ScopedReductionTuning/coveringBudget`` rows, every combination of two leaves' representatives can be tried.
/// - **Large domain, one parameter**: the ends of the range, alternating lowest and highest and working inward, up to ``ScopedReductionTuning/coveringBudget`` rows. Pairwise covering needs two parameters, and a range that a lift has just widened fails at its edges when it fails at all: the values the previous configuration could not express are the ones farthest from where it sat.
struct ScopedCoveringRows {
    private let exhaustiveThreshold: UInt64
    private let coveringBudget: Int
    private let maxCoveredPositions: Int

    // MARK: - State

    private var baseSequence: ChoiceSequence = .init([])
    private var valuePositions: [ValuePosition] = []

    /// Pre-built probes for the exhaustive regime. Empty when using pull-based.
    private var exhaustiveProbes: [CoveringArrayRow] = []
    private var exhaustiveProbeIndex = 0

    /// Pull-based generator for the pairwise regime. Nil when using exhaustive.
    private var generator: BalancedCoveringArrayGenerator?
    private var pullProbeCount = 0
    /// Each leaf's representative offsets in the pairwise regime, which the generator's row values index into.
    private var representativeOffsets: [[UInt64]] = []

    /// Reads ``ScopedReductionTuning/coveringExhaustiveThreshold``, ``ScopedReductionTuning/coveringBudget``, and ``ScopedReductionTuning/maxCoveredPositions``.
    init(tuning: ScopedReductionTuning) {
        exhaustiveThreshold = tuning.coveringExhaustiveThreshold
        coveringBudget = tuning.coveringBudget
        maxCoveredPositions = tuning.maxCoveredPositions
    }

    private struct ValuePosition {
        let index: Int
        let domainLower: UInt64
        let domainSize: UInt64
        let tag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
    }

    /// Starts a pass over the value entries in `positionRange`, up to ``ScopedReductionTuning/maxCoveredPositions``.
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
        generator = nil
        pullProbeCount = 0
        representativeOffsets = []

        guard valuePositions.isEmpty == false else {
            return
        }

        let totalSpace = computeTotalSpace(valuePositions)

        if totalSpace <= exhaustiveThreshold {
            exhaustiveProbes = buildExhaustiveRows(count: Int(totalSpace))
        } else if valuePositions.count == 1 {
            exhaustiveProbes = buildRangeEndRows(domainSize: totalSpace)
        } else {
            // Pull-based pairwise coverage over each leaf's representatives. Rows are generated lazily in nextProbe().
            let perLeafCount = CoveringRepresentatives.perLeafCount(rowBudget: coveringBudget)
            representativeOffsets = valuePositions.map {
                CoveringRepresentatives.offsets(domainSize: $0.domainSize, count: perLeafCount)
            }
            generator = BalancedCoveringArrayGenerator(domainSizes: representativeOffsets.map { UInt64($0.count) })
        }
    }

    /// The next assignment written over the base sequence, or nil when the regime is exhausted.
    mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        let row: CoveringArrayRow?

        if generator != nil {
            guard pullProbeCount < coveringBudget else {
                return nil
            }
            row = generator?.next()
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
            let valueIndex = representativeOffsets.isEmpty
                ? row.values[offset]
                : representativeOffsets[offset][Int(row.values[offset])]
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
        return ValuePosition(
            index: index,
            domainLower: validRange.lowerBound,
            domainSize: validRange.saturatingCount,
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

    /// Builds rows for a single parameter whose domain exceeds the exhaustive threshold: the lowest value, the highest, the second lowest, the second highest, and so on, until ``ScopedReductionTuning/coveringBudget`` rows or the ends meet.
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

    /// Builds exhaustive rows in shortlex order (leftmost coordinate changes slowest).
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
