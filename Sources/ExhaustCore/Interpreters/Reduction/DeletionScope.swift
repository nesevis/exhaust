//
//  DeletionScope.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/4/2026.
//


/// A scoped region for structural deletion within base descent.
///
/// When ``positionRange`` is set, deletion targets are filtered by position range (DAG-driven). When `nil`, targets are filtered by bind depth (bind-free fallback).
struct DeletionScope {
    /// The position range to scope deletion targets to, or `nil` for depth-based filtering.
    let positionRange: ClosedRange<Int>?

    /// The bind depth for decoder selection.
    let depth: Int

    /// Sequence index of the bind-inner value that controls the sequence length within this scope.
    /// Set for bind-inner scopes where the inner value determines the bound sequence length.
    let bindInnerValueIndex: Int?

    init(positionRange: ClosedRange<Int>?, depth: Int, bindInnerValueIndex: Int? = nil) {
        self.positionRange = positionRange
        self.depth = depth
        self.bindInnerValueIndex = bindInnerValueIndex
    }
}