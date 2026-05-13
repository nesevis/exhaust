//
//  BranchData.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/5/2026.
//

/// Metadata for a single branch in a ChoiceTree branch site.
public struct BranchData: Hashable, Sendable {
    public var fingerprint: UInt64
    public var weight: UInt64
    public var id: UInt64
    public var branchCount: UInt64
    public var choice: ChoiceTree
    public var isSelected: Bool

    package init(
        fingerprint: UInt64,
        weight: UInt64,
        id: UInt64,
        branchCount: UInt64,
        choice: ChoiceTree,
        isSelected: Bool = false
    ) {
        self.fingerprint = fingerprint
        self.weight = weight
        self.id = id
        self.branchCount = branchCount
        self.choice = choice
        self.isSelected = isSelected
    }
}
