//
//  ReflectiveGenerator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/7/2025.
//

@testable import Exhaust
import Testing

@discardableResult
func validateGenerator<Output: Equatable>(_ gen: ReflectiveGenerator<Output>) throws -> (recipe: ChoiceTree, instance: Output) {
    var iterator = GeneratorIterator(gen)
    if let instance = iterator.next() {
        let recipe = try #require(try Interpreters.reflect(gen, with: instance))
        let replay = try #require(try Interpreters.replay(gen, using: recipe))
        #expect(instance == replay)
        return (recipe, instance)
    } else {
        fatalError("Boo")
    }
}
