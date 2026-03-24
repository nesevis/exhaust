//
//  CoveringArrayRow.swift
//  Exhaust
//

/// A single row in a covering array, mapping parameter indices to value indices.
public struct CoveringArrayRow: @unchecked Sendable {
    /// `values[i]` is a value index in `0..<parameters[i].domainSize`.
    public var values: [UInt64]

    public init(values: [UInt64]) {
        self.values = values
    }
}
