//
//  DownstreamPick.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/3/2026.
//

/// Runtime strategy selection for the downstream role in a composition.
///
/// A `pick` over the encoder space: at ``start()`` time, computes fibre characteristics
/// (total space and parameter count) and selects the first alternative whose predicate
/// matches. The selected encoder handles all ``nextProbe()`` calls until the next ``start()``.
///
/// This is one morphism in the S-J algebra — the pick is internal to the encoder, not a
/// branching composition. The factory builds the pick with declared alternatives; the
/// closed-loop reducer can modify alternatives without changing the composition's structure.
///
/// ## Convergence transfer safety
///
/// When the selected alternative changes between upstream iterations (the fibre grew or
/// shrank past a threshold), convergence records from the previous alternative are invalid.
/// ``isConvergenceTransferSafe`` returns `false` in this case, and ``KleisliComposition``
/// cold-starts the transfer.
struct DownstreamPick: ComposableEncoder {
    /// A candidate downstream strategy with a selection predicate.
    struct Alternative {
        /// The encoder to use when this alternative is selected.
        let encoder: any ComposableEncoder
        /// Returns true if this alternative should handle the given fibre.
        /// - Parameters:
        ///   - totalSpace: product of domain sizes across downstream value positions.
        ///   - parameterCount: number of value positions in the downstream range.
        let predicate: (UInt64, Int) -> Bool
    }

    let alternatives: [Alternative]

    init(alternatives: [Alternative]) {
        self.alternatives = alternatives
    }

    var name: EncoderName {
        selectedEncoder?.name ?? .kleisliComposition
    }

    let phase = ReductionPhase.exploration

    // MARK: - State

    private var selectedIndex: Int?
    private var previousSelectedIndex: Int?
    private(set) var selectedEncoder: (any ComposableEncoder)?

    // MARK: - ComposableEncoder

    var isConvergenceTransferSafe: Bool {
        guard let current = selectedIndex, let previous = previousSelectedIndex else {
            return false
        }
        return current == previous
    }

    var convergenceRecords: [Int: ConvergedOrigin] {
        selectedEncoder?.convergenceRecords ?? [:]
    }

    func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        // Conservative: sum of all alternatives' costs.
        var total = 0
        for alternative in alternatives {
            if let cost = alternative.encoder.estimatedCost(
                sequence: sequence, tree: tree,
                positionRange: positionRange, context: context
            ) {
                total += cost
            }
        }
        return total > 0 ? total : nil
    }

    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        previousSelectedIndex = selectedIndex

        // Compute fibre characteristics from the sequence and position range.
        let (totalSpace, parameterCount) = computeFibreCharacteristics(
            sequence: sequence, positionRange: positionRange
        )

        // Select first matching alternative.
        for (index, alternative) in alternatives.enumerated() {
            if alternative.predicate(totalSpace, parameterCount) {
                selectedIndex = index
                var encoder = alternative.encoder
                encoder.start(
                    sequence: sequence,
                    tree: tree,
                    positionRange: positionRange,
                    context: context
                )
                selectedEncoder = encoder
                return
            }
        }

        // No alternative matched — clear selection.
        selectedIndex = nil
        selectedEncoder = nil
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        selectedEncoder?.nextProbe(lastAccepted: lastAccepted)
    }

    // MARK: - Fibre Characteristics

    private func computeFibreCharacteristics(
        sequence: ChoiceSequence,
        positionRange: ClosedRange<Int>
    ) -> (totalSpace: UInt64, parameterCount: Int) {
        var parameterCount = 0
        var product: UInt64 = 1
        var overflowed = false

        for index in positionRange {
            guard index < sequence.count else { break }
            guard let value = sequence[index].value,
                  let validRange = value.validRange
            else { continue }

            parameterCount += 1
            let domainSize = validRange.upperBound - validRange.lowerBound + 1
            let (result, overflow) = product.multipliedReportingOverflow(by: domainSize)
            if overflow || result > UInt64.max / 2 {
                overflowed = true
                break
            }
            product = result
        }

        return (overflowed ? UInt64.max : product, parameterCount)
    }
}
