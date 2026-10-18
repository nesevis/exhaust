//
//  ReductionComposition.swift
//  Exhaust
//

// MARK: - Composition Helpers

/// Shared pieces of the composed encoders' reducers.
enum ReductionComposition {
    /// Marks every upstream leaf change as reshaping, so acceptance triggers a full rebuild.
    static func reshaping(_ upstreamProbe: ProjectedMutation) -> ProjectedMutation {
        guard case let .leafValues(upstreamChanges) = upstreamProbe else {
            return upstreamProbe
        }
        let reshapeChanges = upstreamChanges.map { change in
            LeafChange(
                leafNodeID: change.leafNodeID,
                newValue: change.newValue,
                mayReshape: true
            )
        }
        return .leafValues(reshapeChanges)
    }
}
