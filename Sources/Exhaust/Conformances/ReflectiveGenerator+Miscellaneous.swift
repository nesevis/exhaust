//
//  ReflectiveGenerator+Miscellaneous.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

@_spi(ExhaustInternal) import ExhaustCore

public extension ReflectiveGenerator {
    /// Creates a generator that always produces the same constant value.
    static func just(_ value: Value) -> ReflectiveGenerator<Value> {
        Gen.just(value)
    }

    static func bool() -> ReflectiveGenerator<Bool> {
        Gen.pick(choices: [
            (1, Gen.just(true)),
            (1, Gen.just(false)),
        ])
    }

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
    static func oneOf(weighted choices: (Int, ReflectiveGenerator<Value>)...) -> ReflectiveGenerator<Value> {
        Gen.pick(choices: choices.map { ($0.0, $0.1) })
    }
}

public extension ReflectiveGenerator where Value: CaseIterable, Value.AllCases.Index == Int {
    /// Creates a generator that randomly selects from all cases of a `CaseIterable` type.
    static func oneOf(_ type: Value.Type) -> ReflectiveGenerator<Value> {
        Gen.choose(from: type.allCases)
    }
}

public extension ReflectiveGenerator where Operation == ReflectiveOperation {
    func optional() -> ReflectiveGenerator<Value?> {
        Gen.pick(choices: [
            (1, Gen.just(.none)),
            (5, asOptional()),
        ])
    }
}
