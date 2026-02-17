//
//  Shrinkable.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

// Not used anywhere - ignore

protocol Shrinkable: Comparable, Hashable, Equatable {
    var shrinkingStrategies: ShrinkingStrategies { get }
}
