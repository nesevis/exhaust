// MARK: - Fibre Covering Encoder

/// Searches a fibre for any failing point by systematically covering value combinations.
///
/// Unlike per-coordinate minimizers (``ZeroValueEncoder``, ``BinarySearchToSemanticSimplestEncoder``), this encoder does not assume the current state already fails the property. It searches the fibre space for ANY assignment that fails — the right strategy for the downstream slot of a ``KleisliComposition``, where the lifted state may pass the property and a failure needs to be discovered.
///
/// Two regimes based on the fibre's total domain size:
/// - **Small fibres** (total space ≤ ``exhaustiveThreshold``): exhaustive enumeration of all value assignments via mixed-radix counting.
/// - **Large fibres**: pairwise covering array (strength 2) via IPOG, reusing the existing ``CoveringArray.bestFitting(budget:profile:)`` infrastructure. Guarantees every pair of parameter values appears in at least one probe.
public struct FibreCoveringEncoder: PointEncoder {
    public let name: EncoderName = .kleisliComposition
    public let phase: ReductionPhase = .exploration

    /// Maximum number of combinations for exhaustive enumeration.
    public static let exhaustiveThreshold: UInt64 = 64

    /// Maximum probes for the covering array regime.
    public static let coveringBudget: UInt64 = 64

    // MARK: - State

    private var baseSequence: ChoiceSequence = .init([])
    private var valuePositions: [ValuePosition] = []
    private var probes: [CoveringArrayRow] = []
    private var probeIndex = 0
    private var isExhaustive = false

    /// The total fibre space computed at `start()` time. Used by the driver for profiling (fibre size vs exhaustive threshold).
    public private(set) var lastComputedFibreSize: UInt64 = 0

    /// The number of probes generated at `start()` time. Zero means the fibre was too large or had too few parameters for pairwise.
    public var probeCount: Int { probes.count }

    private struct ValuePosition {
        let index: Int
        let domainLower: UInt64
        let domainSize: UInt64
        let tag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
    }

    public init() {}

    // MARK: - PointEncoder

    public func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        let positions = collectValuePositions(in: positionRange, from: sequence)
        guard positions.isEmpty == false else { return nil }
        let totalSpace = computeTotalSpace(positions)
        if totalSpace <= Self.exhaustiveThreshold {
            return Int(totalSpace)
        }
        // Covering array size is hard to predict without building it.
        // Conservative estimate: min(budget, totalSpace).
        return Int(min(Self.coveringBudget, totalSpace))
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        baseSequence = sequence
        valuePositions = collectValuePositions(in: positionRange, from: sequence)
        probeIndex = 0
        probes = []
        isExhaustive = false

        guard valuePositions.isEmpty == false else {
            lastComputedFibreSize = 0
            return
        }

        let totalSpace = computeTotalSpace(valuePositions)
        lastComputedFibreSize = totalSpace

        if totalSpace <= Self.exhaustiveThreshold {
            // Exhaustive: generate all combinations as rows
            isExhaustive = true
            probes = buildExhaustiveRows(count: Int(totalSpace))
        } else if valuePositions.count >= 2, valuePositions.count <= 20 {
            // Covering array: pairwise coverage via IPOG.
            // Cap at 20 parameters — beyond that the fibre is too large for
            // the covering encoder to add value. The structural encoders
            // (deletion, branch simplification) have more work to do before
            // the fibre is small enough to search.
            let parameters = valuePositions.enumerated().map { offset, position in
                FiniteParameter(
                    index: offset,
                    domainSize: position.domainSize,
                    kind: .chooseBits(
                        range: 0 ... max(position.domainSize, 1) - 1,
                        tag: position.tag
                    )
                )
            }
            let profile = FiniteDomainProfile(
                parameters: parameters,
                totalSpace: totalSpace
            )
            if let covering = CoveringArray.generate(
                profile: profile,
                strength: 2,
                rowBudget: Int(Self.coveringBudget)
            ) {
                probes = covering.rows
            }
        } else {
            // Too few parameters for a covering array, too large for exhaustive.
            // Return early — structural encoders have more work to do.
            return
        }
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard probeIndex < probes.count else { return nil }

        let row = probes[probeIndex]
        probeIndex += 1

        var candidate = baseSequence
        for (offset, position) in valuePositions.enumerated() {
            guard offset < row.values.count else { break }
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

    /// Builds exhaustive rows as ``CoveringArrayRow`` values using mixed-radix decomposition.
    private func buildExhaustiveRows(count: Int) -> [CoveringArrayRow] {
        var rows: [CoveringArrayRow] = []
        rows.reserveCapacity(count)
        for combinationIndex in 0 ..< count {
            var values = [UInt64](repeating: 0, count: valuePositions.count)
            var remaining = combinationIndex
            for (offset, position) in valuePositions.enumerated() {
                let domainSize = Int(position.domainSize)
                values[offset] = UInt64(remaining % domainSize)
                remaining /= domainSize
            }
            rows.append(CoveringArrayRow(values: values))
        }
        return rows
    }
}
