//
//  BinarySearchToRangeMinimumEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

// Deprecated: use BinarySearchEncoder(configuration: .rangeMinimum) instead.

/// A binary search encoder configured for downward-only search toward range minimum.
///
/// This type is a convenience wrapper around ``BinarySearchEncoder`` with ``BinarySearchEncoder/Configuration/rangeMinimum`` configuration.
public struct BinarySearchToRangeMinimumEncoder: ComposableEncoder {
    private var inner: BinarySearchEncoder

    public init() {
        inner = BinarySearchEncoder(configuration: .rangeMinimum)
    }

    public var name: EncoderName {
        inner.name
    }

    public var phase: ReductionPhase {
        inner.phase
    }

    public var convergenceRecords: [Int: ConvergedOrigin] {
        inner.convergenceRecords
    }

    public func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        inner.estimatedCost(sequence: sequence, tree: tree, positionRange: positionRange, context: context)
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        inner.start(sequence: sequence, tree: tree, positionRange: positionRange, context: context)
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        inner.nextProbe(lastAccepted: lastAccepted)
    }
}
