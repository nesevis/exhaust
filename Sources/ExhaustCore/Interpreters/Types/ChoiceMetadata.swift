//
//  ChoiceMetadata.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

@_spi(ExhaustInternal) public struct ChoiceMetadata: Hashable, Equatable, Sendable {
    @_spi(ExhaustInternal) public let validRange: ClosedRange<UInt64>?
    /// Whether the range was explicitly specified by the user (e.g. `.array(length: 1...5)`)
    /// rather than derived from size scaling.
    @_spi(ExhaustInternal) public let isRangeExplicit: Bool

    @_spi(ExhaustInternal) public init(validRange: ClosedRange<UInt64>?, isRangeExplicit: Bool = false) {
        self.validRange = validRange
        self.isRangeExplicit = isRangeExplicit
    }
}
