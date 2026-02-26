//
//  ReflectiveGenerator+Miscellaneous.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

public extension ReflectiveGenerator {
    static func optional(_ gen: ReflectiveGenerator<Value>) -> ReflectiveGenerator<Value?> {
        Gen.pick(choices: [
            (1, Gen.just(.none)),
            (5, gen.asOptional()),
        ])
    }

    /// Creates a generator that randomly selects from one of the provided generators with equal weight.
    static func oneOf(_ generators: ReflectiveGenerator<Value>...) -> ReflectiveGenerator<Value> {
        Gen.pick(choices: generators.map { (1, $0) })
    }

    /// Creates a generator that randomly selects from weighted generators.
    static func oneOf(_ choices: (Int, ReflectiveGenerator<Value>)...) -> ReflectiveGenerator<Value> {
        Gen.pick(choices: choices.map { ($0.0, $0.1) })
    }
}
