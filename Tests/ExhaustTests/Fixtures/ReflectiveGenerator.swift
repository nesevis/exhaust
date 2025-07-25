//
//  ReflectiveGenerator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/7/2025.
//

@testable import Exhaust
import Testing

@discardableResult
func validateGenerator<Output: Equatable>(_ gen: ReflectiveGenerator<Any, Output>) throws -> (recipe: ChoiceTree, instance: Output) {
    let instance = try #require(Interpreters.generate(gen))
    let recipe = try #require(try Interpreters.reflect(gen, with: instance))
    let replay = try #require(try Interpreters.replay(gen, using: recipe))
    print()
    return (recipe, instance)
}
