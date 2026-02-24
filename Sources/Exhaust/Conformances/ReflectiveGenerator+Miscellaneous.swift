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
}
