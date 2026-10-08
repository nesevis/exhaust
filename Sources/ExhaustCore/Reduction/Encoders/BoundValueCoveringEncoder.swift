// MARK: - Bound Value Covering Encoder

/// Searches a bound subtree for any failing point by systematically covering value combinations.
///
/// Unlike per-coordinate minimizers, this encoder does not assume the current state already fails the property. It searches the bound value space for ANY assignment that fails — the right strategy for the downstream slot of a ``GraphComposedEncoder``, where the lifted state may pass the property and a failure needs to be discovered.
///
/// Only the first ``maxCoveredPositions`` value positions are searched; the rest keep their base values.
///
/// Three regimes based on the searched leaves' total domain size:
/// - **Small domains** (total space ≤ ``exhaustiveThreshold``): exhaustive enumeration of all value assignments via mixed-radix counting.
/// - **Large domains, 2 or more parameters**: pairwise covering (strength 2) via ``BalancedCoveringArrayGenerator``. Each ``nextProbe(lastAccepted:)`` call pulls the next greedy row — no upfront batch build.
/// - **Large domain, one parameter**: the ends of the range, alternating lowest and highest and working inward, up to ``coveringBudget`` rows. Pairwise covering needs two parameters, and a range that a lift has just widened fails at its edges when it fails at all: the values the previous configuration could not express are the ones farthest from where it sat.
package struct BoundValueCoveringEncoder: ComposableEncoder {
    public let name: EncoderName = .boundValueSearch

    /// Maximum number of combinations for exhaustive enumeration.
    public static let exhaustiveThreshold: UInt64 = 32

    /// Maximum probes for the covering array regime.
    public static let coveringBudget: Int = 64

    /// Maximum number of value positions a pass searches. Positions past it, in collection order, stay fixed at their base values.
    ///
    /// Pairwise covering builds one slice per parameter pair, so its setup grows quadratically with the parameter count. The reduction deadline is only checked between probes, so a bound array of a few thousand elements would stall the reducer inside generator construction where the deadline cannot stop it.
    public static let maxCoveredPositions: Int = 64

    // MARK: - State

    private var baseSequence: ChoiceSequence = .init([])
    private var valuePositions: [ValuePosition] = []

    /// Pre-built probes for the exhaustive regime. Empty when using pull-based.
    private var exhaustiveProbes: [CoveringArrayRow] = []
    private var exhaustiveProbeIndex = 0

    /// Pull-based generator for the pairwise regime. Nil when using exhaustive.
    private var generator: BalancedCoveringArrayGenerator?
    private var pullProbeCount = 0

    /// The total bound value space computed at `start()` time. Used by the driver for profiling (domain size vs exhaustive threshold).
    public private(set) var lastComputedDomainSize: UInt64 = 0

    /// The number of probes emitted so far.
    public var probeCount: Int {
        if generator != nil {
            return pullProbeCount
        }
        return exhaustiveProbeIndex
    }

    private struct ValuePosition {
        let index: Int
        let domainLower: UInt64
        let domainSize: UInt64
        let tag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
    }

    /// Creates an encoder with no pre-built state.
    public init() {}

    // MARK: - ComposableEncoder

    /// Estimates the number of probes needed to cover the bound subtree within the given position range.
    public func estimatedCost(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange: ClosedRange<Int>
    ) -> Int? {
        let positions = collectValuePositions(in: positionRange, from: sequence)
        guard positions.isEmpty == false else { return nil }
        let totalSpace = computeTotalSpace(positions)
        if totalSpace <= Self.exhaustiveThreshold {
            return Int(totalSpace)
        }
        return min(Self.coveringBudget, Int(min(totalSpace, UInt64(Int.max))))
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange: ClosedRange<Int>
    ) {
        begin(
            sequence: sequence,
            valuePositions: collectValuePositions(in: positionRange, from: sequence)
        )
    }

    /// Starts a pass over the value entries at `positions` only, in the order given. Every other entry stays fixed, which a spanning range does not guarantee: a bound value scope can leave out a nested bind's controller that sits between two of its leaves.
    package mutating func start(
        sequence: ChoiceSequence,
        positions: [Int]
    ) {
        var collected: [ValuePosition] = []
        for index in positions {
            guard collected.count < Self.maxCoveredPositions else { break }
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

        guard valuePositions.isEmpty == false else {
            lastComputedDomainSize = 0
            return
        }

        let totalSpace = computeTotalSpace(valuePositions)
        lastComputedDomainSize = totalSpace

        if totalSpace <= Self.exhaustiveThreshold {
            exhaustiveProbes = buildExhaustiveRows(count: Int(totalSpace))
        } else if valuePositions.count == 1 {
            exhaustiveProbes = buildRangeEndRows(domainSize: totalSpace)
        } else {
            // Pull-based pairwise coverage. Rows are generated lazily in nextProbe().
            // Cap each domain to coveringBudget: we emit at most that many rows, so larger domains add no useful coverage and would produce enormous allocations (for example, Unicode scalar domains of ~1.1M values would create O(domain²) coverage matrices).
            let cappedDomains = valuePositions.map {
                min($0.domainSize, UInt64(Self.coveringBudget))
            }
            generator = BalancedCoveringArrayGenerator(domainSizes: cappedDomains)
        }
    }

    public mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        let row: CoveringArrayRow?

        if generator != nil {
            guard pullProbeCount < Self.coveringBudget else { return nil }
            row = generator?.next()
            if row != nil { pullProbeCount += 1 }
        } else {
            guard exhaustiveProbeIndex < exhaustiveProbes.count else { return nil }
            row = exhaustiveProbes[exhaustiveProbeIndex]
            exhaustiveProbeIndex += 1
        }

        guard let row else { return nil }

        var candidate = baseSequence
        var offset = 0
        while offset < valuePositions.count {
            guard offset < row.values.count else { break }
            let position = valuePositions[offset]
            let valueIndex = row.values[offset]
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
            guard index < sequence.count, positions.count < Self.maxCoveredPositions else { break }
            guard let position = valuePosition(at: index, in: sequence) else { continue }
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

    /// Builds rows for a single parameter whose domain exceeds the exhaustive threshold: the lowest value, the highest, the second lowest, the second highest, and so on, until ``coveringBudget`` rows or the ends meet.
    private func buildRangeEndRows(domainSize: UInt64) -> [CoveringArrayRow] {
        var rows: [CoveringArrayRow] = []
        rows.reserveCapacity(Self.coveringBudget)
        var step: UInt64 = 0
        while rows.count < Self.coveringBudget {
            let low = step
            let high = domainSize &- 1 &- step
            guard low <= high else {
                break
            }
            rows.append(CoveringArrayRow(values: [low]))
            if high != low, rows.count < Self.coveringBudget {
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

// MARK: - Graph Bound Value Covering Encoder

/// Adapts ``BoundValueCoveringEncoder`` (a ``ComposableEncoder``) to the ``GraphEncoder`` protocol so it can be used as the downstream of a ``GraphComposedEncoder``.
///
/// The downstream slot of a bound value composition needs to *discover* failures in the lifted bound subtree, not minimize toward a known target. Per-coordinate value-search encoders (``GraphValueEncoder``) only move from the current value toward its semantic simplest, so they cannot find counterexamples that require moving *away* from the target — for example, the [1, 0] coupling that fails the property when the binary search starts from [0, 0].
///
/// ``BoundValueCoveringEncoder`` enumerates the entire bound value space (exhaustively for ≤ 128 combinations, pairwise covering for larger spaces) and is the right tool for that job.
///
/// The wrapper expects the scope's operation to be ``MinimizationScope/valueLeaves(_:)``: the inner encoder is started on the scope's `baseSequence` at exactly the leaves' positions. Entries between them, such as a nested bind's controller the scope leaves out, stay fixed.
struct GraphBoundValueCoveringEncoder: GraphEncoder {
    let name: EncoderName = .boundValueSearch

    private var inner = BoundValueCoveringEncoder()
    private var leafEntries: [LeafEntry] = []
    private var hasInner = false

    mutating func start(scope: EncoderInput) {
        leafEntries = []
        hasInner = false

        guard case let .minimize(.valueLeaves(integerScope)) = scope.transformation.operation else {
            return
        }
        let graph = scope.graph
        let sequence = scope.baseSequence

        var positions: [Int] = []
        var validEntries: [LeafEntry] = []
        for entry in integerScope.leaves {
            guard entry.nodeID < graph.nodes.count,
                  let range = graph.nodes[entry.nodeID].positionRange,
                  range.lowerBound < sequence.count,
                  sequence[range.lowerBound].value != nil
            else { continue }
            positions.append(range.lowerBound)
            validEntries.append(entry)
        }
        guard validEntries.isEmpty == false else { return }

        leafEntries = validEntries
        // Ascending, so covering rows assign values in sequence order.
        inner.start(sequence: sequence, positions: positions.sorted())
        hasInner = true
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard hasInner else { return nil }
        guard let built = inner.nextProbe(lastAccepted: lastAccepted) else { return nil }
        // The composition replaces this mutation with the upstream's reshape mutation, so the empty leafValues is a placeholder; the candidate carries the downstream values.
        candidate = built
        return .leafValues([])
    }
}
