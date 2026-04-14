// MARK: - Fibre Covering Encoder

/// Searches a fibre for any failing point by systematically covering value combinations.
///
/// Unlike per-coordinate minimizers, this encoder does not assume the current state already fails the property. It searches the fibre space for ANY assignment that fails — the right strategy for the downstream slot of a ``GraphComposedEncoder``, where the lifted state may pass the property and a failure needs to be discovered.
///
/// Two regimes based on the fibre's total domain size:
/// - **Small fibres** (total space ≤ ``exhaustiveThreshold``): exhaustive enumeration of all value assignments via mixed-radix counting.
/// - **Large fibres** (2 or more parameters): pairwise covering (strength 2) via the density method (``PullBasedCoveringArrayGenerator``). Each ``nextProbe(lastAccepted:)`` call pulls the next greedy row — no upfront batch build.
package struct FibreCoveringEncoder: ComposableEncoder {
    public let name: EncoderName = .boundValueSearch

    /// Maximum number of combinations for exhaustive enumeration.
    public static let exhaustiveThreshold: UInt64 = 32

    /// Maximum probes for the covering array regime.
    public static let coveringBudget: Int = 64

    // MARK: - State

    private var baseSequence: ChoiceSequence = .init([])
    private var valuePositions: [ValuePosition] = []

    /// Pre-built probes for the exhaustive regime. Empty when using pull-based.
    private var exhaustiveProbes: [CoveringArrayRow] = []
    private var exhaustiveProbeIndex = 0

    /// Pull-based generator for the pairwise regime. Nil when using exhaustive.
    private var generator: PullBasedCoveringArrayGenerator?
    private var pullProbeCount = 0

    /// The total fibre space computed at `start()` time. Used by the driver for profiling (fibre size vs exhaustive threshold).
    public private(set) var lastComputedFibreSize: UInt64 = 0

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

    public init() {}

    // MARK: - ComposableEncoder

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
        baseSequence = sequence
        valuePositions = collectValuePositions(in: positionRange, from: sequence)
        exhaustiveProbeIndex = 0
        exhaustiveProbes = []
        generator?.deallocate()
        generator = nil
        pullProbeCount = 0

        guard valuePositions.isEmpty == false else {
            lastComputedFibreSize = 0
            return
        }

        let totalSpace = computeTotalSpace(valuePositions)
        lastComputedFibreSize = totalSpace

        if totalSpace <= Self.exhaustiveThreshold {
            exhaustiveProbes = buildExhaustiveRows(count: Int(totalSpace))
        } else if valuePositions.count >= 2 {
            // Pull-based pairwise coverage. Rows are generated lazily in nextProbe().
            // Cap each domain to coveringBudget: we emit at most that many rows, so
            // larger domains add no useful coverage and would produce enormous bit
            // vector allocations (for example, Unicode scalar domains of ~1.1M values
            // clamp to 65535 in PullBasedCoveringArrayGenerator, giving a 536 MB bit
            // vector and O(65535²) work per row).
            let cappedDomains = valuePositions.map {
                min($0.domainSize, UInt64(Self.coveringBudget))
            }
            generator = PullBasedCoveringArrayGenerator(
                domainSizes: cappedDomains,
                strength: 2
            )
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
            let bitPattern = position.domainLower + valueIndex

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
            guard index < sequence.count else { break }
            guard let value = sequence[index].value,
                  let validRange = value.validRange
            else { continue }

            let domainSize = validRange.upperBound - validRange.lowerBound + 1
            positions.append(ValuePosition(
                index: index,
                domainLower: validRange.lowerBound,
                domainSize: domainSize,
                tag: value.choice.tag,
                validRange: validRange,
                isRangeExplicit: value.isRangeExplicit
            ))
        }
        return positions
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
