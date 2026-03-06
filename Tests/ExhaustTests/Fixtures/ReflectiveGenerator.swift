//
//  ReflectiveGenerator.swift
//  ExhaustTests
//

import Testing
@testable import Exhaust
import ExhaustCore

@discardableResult
func validateGenerator<Output: Equatable>(_ gen: ReflectiveGenerator<Output>) throws -> (recipe: ChoiceTree, instance: Output) {
    var iterator = ValueInterpreter(gen)
    if let instance = try iterator.next() {
        let recipe = try #require(try Interpreters.reflect(gen, with: instance))
        let replay = try #require(try Interpreters.replay(gen, using: recipe))
        #expect(instance == replay)
        return (recipe, instance)
    } else {
        fatalError("Boo")
    }
}
