//
//  BindSpanIndex.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/3/2026.
//

/// Lightweight index mapping ChoiceSequence positions to bind span membership.
///
/// Built once per reducer loop iteration when the sequence changes. Maps each bind
/// span's inner and bound child ranges so that strategies can:
/// 1. Skip bound entries (they'll be re-derived when the inner changes)
/// 2. Route mutations that touch a bind's inner subtree through ``GuidedMaterializer``
public struct BindSpanIndex {
    /// A single bind region with the ranges of its inner and bound children.
    public struct BindRegion {
        /// Full bind span including `.bind(true)` and `.bind(false)` markers.
        public let bindSpanRange: ClosedRange<Int>
        /// Inner child range (first child of the bind).
        public let innerRange: ClosedRange<Int>
        /// Bound child range (second child of the bind).
        public let boundRange: ClosedRange<Int>
    }

    public let regions: [BindRegion]

    /// Builds the index by scanning for `.bind(true)` container spans and extracting
    /// their inner (first child) and bound (second child) ranges.
    public init(from sequence: ChoiceSequence) {
        let containerSpans = ChoiceSequence.extractContainerSpans(from: sequence)
        var regions = [BindRegion]()
        for span in containerSpans {
            guard case .bind(true) = span.kind else { continue }
            let children = ChoiceSequence.extractImmediateChildren(from: sequence, in: span.range)
            guard children.count >= 2 else { continue }
            regions.append(BindRegion(
                bindSpanRange: span.range,
                innerRange: children[0].range,
                boundRange: children[1].range,
            ))
        }
        self.regions = regions
    }

    /// Whether any bind spans exist.
    public var isEmpty: Bool { regions.isEmpty }

    /// Returns the ``BindRegion`` whose inner range contains the given index, or `nil`.
    public func bindRegionForInnerIndex(_ index: Int) -> BindRegion? {
        regions.first { $0.innerRange.contains(index) }
    }

    /// Whether the index falls inside any bind's bound range.
    public func isInBoundSubtree(_ index: Int) -> Bool {
        regions.contains { $0.boundRange.contains(index) }
    }

    /// The number of bound ranges that contain this index (bind nesting depth).
    public func bindDepth(at index: Int) -> Int {
        regions.count(where: { $0.boundRange.contains(index) })
    }

    /// The maximum bind nesting depth across all positions.
    public var maxBindDepth: Int {
        guard regions.isEmpty == false else { return 0 }
        var maxDepth = 0
        for region in regions {
            maxDepth = max(maxDepth, bindDepth(at: region.boundRange.lowerBound))
        }
        return maxDepth
    }
}
