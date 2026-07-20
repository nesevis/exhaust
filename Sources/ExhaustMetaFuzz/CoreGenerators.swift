import ExhaustCore
import Foundation

/// ASCII character generator (U+0020–U+007E) with reflection support.
package func asciiCharGen() -> Generator<Character> {
    let srs = CharacterSet(charactersIn: Unicode.Scalar(0x0020)! ... Unicode.Scalar(0x007E)!).scalarRangeSet()
    return Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars"
                )
            }
            return srs.index(of: scalar)
        },
        Gen.choose(in: 0 ... srs.scalarCount - 1)
            .map { Character(srs.scalar(at: $0)) }
    )
}

/// Default (non-control, non-illegal Unicode) character generator with reflection support.
package func defaultCharGen() -> Generator<Character> {
    let srs = CharacterSet.illegalCharacters.inverted.subtracting(.controlCharacters).scalarRangeSet()
    return Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars"
                )
            }
            return srs.index(of: scalar)
        },
        Gen.choose(in: 0 ... srs.scalarCount - 1)
            .map { Character(srs.scalar(at: $0)) }
    )
}

/// ASCII string generator with size-scaled length.
package func asciiStringGen() -> Generator<String> {
    let charGen = asciiCharGen()
    return Gen.contramap(
        { (s: String) -> [Character] in s.unicodeScalars.map { Character($0) } },
        Gen.arrayOf(charGen).map { String($0) }
    )
}

/// ASCII string generator with explicit length range.
package func asciiStringGen(length: ClosedRange<UInt64>) -> Generator<String> {
    let srs = CharacterSet(charactersIn: Unicode.Scalar(0x0020)! ... Unicode.Scalar(0x007E)!).scalarRangeSet()
    let charGen = Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars"
                )
            }
            return srs.index(of: scalar)
        },
        Gen.choose(in: 0 ... srs.scalarCount - 1)
            .map { Character(srs.scalar(at: $0)) }
    )
    return Gen.contramap(
        { (s: String) throws -> [Character] in s.unicodeScalars.map { Character($0) } },
        Gen.arrayOf(charGen, within: length).map { String($0) }
    )
}

/// Default Unicode string generator with size-scaled length.
package func stringGen() -> Generator<String> {
    let charGen = defaultCharGen()
    return Gen.contramap(
        { (s: String) -> [Character] in s.unicodeScalars.map { Character($0) } },
        Gen.arrayOf(charGen).map { String($0) }
    )
}

/// String generator from a CharacterSet with explicit length range.
package func stringGen(from characterSet: CharacterSet, length: ClosedRange<UInt64>) -> Generator<String> {
    let cGen = charGen(from: characterSet)
    return Gen.contramap(
        { (s: String) throws -> [Character] in s.unicodeScalars.map { Character($0) } },
        Gen.arrayOf(cGen, within: length).map { String($0) }
    )
}

/// Character generator from a CharacterSet.
package func charGen(from characterSet: CharacterSet) -> Generator<Character> {
    let srs = characterSet.scalarRangeSet()
    return Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars"
                )
            }
            guard srs.contains(scalar) else {
                throw ReflectionError.inputWasOutOfGeneratorRange(
                    "U+\(String(scalar.value, radix: 16, uppercase: true))",
                    range: "ScalarRangeSet(\(srs.scalarCount) scalars)"
                )
            }
            return srs.index(of: scalar)
        },
        Gen.choose(in: 0 ... srs.scalarCount - 1)
            .map { Character(srs.scalar(at: $0)) }
    )
}

/// Makes a generator optional: picks between .none (weight 1) and .some (weight 5).
package func optionalGen<Value>(_ gen: Generator<Value>) -> Generator<Value?> {
    Gen.pick(choices: [
        (1, Gen.just(Value?.none)),
        (5, asOptionalGen(gen)),
    ])
}

/// Wraps a non-optional generator into an optional one (the .some branch).
package func asOptionalGen<Value>(_ gen: Generator<Value>) -> Generator<Value?> {
    let description = String(describing: Value.self)
    return .impure(operation: .contramap(
        transform: { result in
            if let optional = result as? Value?, optional == nil {
                throw ReflectionError.reflectedNil(
                    type: description,
                    resultType: String(describing: type(of: result))
                )
            }
            return result as! Value
        },
        next: gen.erase()
    )) { result in
        .pure(result as? Value)
    }
}
