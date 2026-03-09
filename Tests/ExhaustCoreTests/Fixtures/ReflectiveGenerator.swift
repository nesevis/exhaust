//
//  ReflectiveGenerator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/7/2025.
//

import Testing
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

// MARK: - ExhaustCore-level string/character generators

import Foundation

/// ASCII character generator (U+0020–U+007E) with reflection support.
func asciiCharGen() -> ReflectiveGenerator<Character> {
    let srs = CharacterSet(charactersIn: Unicode.Scalar(0x0020)! ... Unicode.Scalar(0x007E)!).scalarRangeSet()
    return Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars",
                )
            }
            return srs.index(of: scalar)
        },
        Gen.choose(in: 0 ... srs.scalarCount - 1)
            ._map { Character(srs.scalar(at: $0)) },
    )
}

/// Default (non-control, non-illegal Unicode) character generator with reflection support.
func defaultCharGen() -> ReflectiveGenerator<Character> {
    let srs = CharacterSet.illegalCharacters.inverted.subtracting(.controlCharacters).scalarRangeSet()
    return Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars",
                )
            }
            return srs.index(of: scalar)
        },
        Gen.choose(in: 0 ... srs.scalarCount - 1)
            ._map { Character(srs.scalar(at: $0)) },
    )
}

/// ASCII string generator with size-scaled length.
func asciiStringGen() -> ReflectiveGenerator<String> {
    let charGen = asciiCharGen()
    return Gen.contramap(
        { (s: String) -> [Character] in s.unicodeScalars.map { Character($0) } },
        Gen.arrayOf(charGen)._map { String($0) },
    )
}

/// Default Unicode string generator with size-scaled length.
func stringGen() -> ReflectiveGenerator<String> {
    let charGen = defaultCharGen()
    return Gen.contramap(
        { (s: String) -> [Character] in s.unicodeScalars.map { Character($0) } },
        Gen.arrayOf(charGen)._map { String($0) },
    )
}

/// Bool generator equivalent to .bool() — picks from [true, false].
func boolGen() -> ReflectiveGenerator<Bool> {
    Gen.choose(from: [true, false])
}

/// Character generator from a CharacterSet.
func charGen(from characterSet: CharacterSet) -> ReflectiveGenerator<Character> {
    let srs = characterSet.scalarRangeSet()
    return Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars",
                )
            }
            return srs.index(of: scalar)
        },
        Gen.choose(in: 0 ... srs.scalarCount - 1)
            ._map { Character(srs.scalar(at: $0)) },
    )
}

/// Makes a generator optional: picks between .none (weight 1) and .some (weight 5).
func optionalGen<Value>(_ gen: ReflectiveGenerator<Value>) -> ReflectiveGenerator<Value?> {
    Gen.pick(choices: [
        (1, Gen.just(Value?.none)),
        (5, asOptionalGen(gen)),
    ])
}

/// Wraps a non-optional generator into an optional one (the .some branch).
func asOptionalGen<Value>(_ gen: ReflectiveGenerator<Value>) -> ReflectiveGenerator<Value?> {
    let description = String(describing: Value.self)
    return .impure(operation: .contramap(
        transform: { result in
            if let optional = result as? Value?, optional == nil {
                throw Interpreters.ReflectionError.reflectedNil(
                    type: description,
                    resultType: String(describing: type(of: result)),
                )
            }
            return result as! Value
        },
        next: gen.erase(),
    )) { result in
        .pure(result as? Value)
    }
}
