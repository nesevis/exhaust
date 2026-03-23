//
//  BinarySearchToSemanticSimplestEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

// Deprecated: use BinarySearchEncoder(configuration: .semanticSimplest) instead.

/// A binary search encoder configured for bidirectional search with cross-zero phase.
///
/// This type is a convenience wrapper around ``BinarySearchEncoder`` with ``BinarySearchEncoder/Configuration/semanticSimplest`` configuration.
public struct BinarySearchToSemanticSimplestEncoder: ComposableEncoder {
    private var inner: BinarySearchEncoder

    public init() {
        inner = BinarySearchEncoder(configuration: .semanticSimplest)
    }

    public var name: EncoderName { inner.name }
    public var phase: ReductionPhase { inner.phase }
    public var convergenceRecords: [Int: ConvergedOrigin] { inner.convergenceRecords }

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
