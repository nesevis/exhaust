import Foundation

// MARK: - Collection Generator Construction

//
// Conditional conformances to ``ExhaustGenerable`` (Array, Dictionary, Set) are not reliably resolved at runtime in xcframework builds — the linker may strip conformance records that are only reachable via dynamic `as?` casts.
//
// ``SynthesizableCollection`` is an unconditional conformance on each collection type (no `where` clause), so it is always present in the binary. The element/key/value type's ``ExhaustGenerable`` conformance is checked at runtime inside the property, where unconditional conformances resolve correctly.

/// Provides a generator for standard library collection types without relying on conditional ``ExhaustGenerable`` conformances.
///
/// Each conformance is unconditional (no `where` clause) so the linker cannot strip it. The element type's ``ExhaustGenerable`` conformance is checked at runtime inside ``synthesizedGenerator``, returning `nil` when the element type has no generator.
package protocol SynthesizableCollection {
    /// Returns a generator for this collection type, or `nil` if the element/key/value types do not conform to ``ExhaustGenerable``.
    static var synthesizedGenerator: AnyGenerator? { get }
}

extension Array: SynthesizableCollection {
    /// Returns ``Gen/arrayOf(_:)`` with the element's default generator, or `nil` if `Element` has no generator.
    package static var synthesizedGenerator: AnyGenerator? {
        guard let elementGen = resolveGenerator(for: Element.self) else { return nil }
        let typed: Generator<Element> = elementGen.map { $0 as! Element }
        return Gen.arrayOf(typed).erase()
    }
}

extension Dictionary: SynthesizableCollection {
    /// Returns ``Gen/dictionaryOf(_:_:)`` with the key and value default generators, or `nil` if either has no generator.
    package static var synthesizedGenerator: AnyGenerator? {
        guard let keyGen = resolveGenerator(for: Key.self),
              let valueGen = resolveGenerator(for: Value.self)
        else { return nil }
        let typedKey: Generator<Key> = keyGen.map { $0 as! Key }
        let typedValue: Generator<Value> = valueGen.map { $0 as! Value }
        return Gen.dictionaryOf(typedKey, typedValue).erase()
    }
}

extension Set: SynthesizableCollection {
    /// Returns ``Gen/setOf(_:)`` with the element's default generator, or `nil` if `Element` has no generator.
    package static var synthesizedGenerator: AnyGenerator? {
        guard let elementGen = resolveGenerator(for: Element.self) else { return nil }
        let typed: Generator<Element> = elementGen.map { $0 as! Element }
        return Gen.setOf(typed).erase()
    }
}

/// Resolves a generator for any type, trying ``ExhaustGenerable`` first and ``SynthesizableCollection`` as a fallback for collection types whose conditional conformances may not survive xcframework linking.
func resolveGenerator(for type: Any.Type) -> AnyGenerator? {
    if let generable = type as? ExhaustGenerable.Type {
        return generable.defaultGenerator
    }
    if let collection = type as? SynthesizableCollection.Type {
        return collection.synthesizedGenerator
    }
    return nil
}

// MARK: - Discovered Collection Generators

//
// ``SynthesizableCollection`` only covers collections whose element/key/value types are themselves ``ExhaustGenerable``. A collection of a nested `Decodable` type — `[Address]`, `Set<Shape>`, `[String: Lineitem]` — has no built-in element generator, so without this it would pin to the example. ``DiscoverableCollection`` discovers the element type's shape from a representative element of the example and builds a real element generator, wrapped in the standard collection combinator so the length and contents vary like a hand-written collection generator.
//
// The conformances are unconditional (matching ``SynthesizableCollection``) so they survive xcframework linking; the element type's `Decodable` conformance is checked at runtime inside each property.

/// Builds a generator for a standard library collection of a non-``ExhaustGenerable`` element type by discovering the element from a representative example value.
package protocol DiscoverableCollection {
    /// Returns a generator that varies the collection's length and contents, or `nil` when the element type is not `Decodable` or the example has no representative element to discover from.
    static func discoveredGenerator(fromExample jsonValue: Any, codingPath: [any CodingKey]) -> AnyGenerator?
}

extension Array: DiscoverableCollection {
    package static func discoveredGenerator(fromExample jsonValue: Any, codingPath: [any CodingKey]) -> AnyGenerator? {
        guard let elementType = Element.self as? any Decodable.Type,
              let array = jsonValue as? [Any],
              let representativeElement = array.first,
              let elementGen = discoverElementGenerator(elementType, fromExample: representativeElement, codingPath: codingPath)
        else { return nil }
        let typed: Generator<Element> = elementGen.map { $0 as! Element }
        return Gen.arrayOf(typed).erase()
    }
}

extension Set: DiscoverableCollection {
    package static func discoveredGenerator(fromExample jsonValue: Any, codingPath: [any CodingKey]) -> AnyGenerator? {
        guard let elementType = Element.self as? any Decodable.Type,
              let array = jsonValue as? [Any],
              let representativeElement = array.first,
              let elementGen = discoverElementGenerator(elementType, fromExample: representativeElement, codingPath: codingPath)
        else { return nil }
        let typed: Generator<Element> = elementGen.map { $0 as! Element }
        return Gen.setOf(typed).erase()
    }
}

extension Dictionary: DiscoverableCollection {
    package static func discoveredGenerator(fromExample jsonValue: Any, codingPath: [any CodingKey]) -> AnyGenerator? {
        guard let dictionary = jsonValue as? [String: Any],
              let representativeValue = dictionary.values.first,
              let valueType = Value.self as? any Decodable.Type,
              let valueGen = discoverElementGenerator(valueType, fromExample: representativeValue, codingPath: codingPath),
              let keyGen = resolveGenerator(for: Key.self)
        else { return nil }
        let typedKey: Generator<Key> = keyGen.map { $0 as! Key }
        let typedValue: Generator<Value> = valueGen.map { $0 as! Value }
        return Gen.dictionaryOf(typedKey, typedValue).erase()
    }
}

/// Discovers a generator for a single `Decodable` element type from a representative example value.
///
/// Runs `Element.init(from:)` once against the example element to record its shape, then builds a reconstructing generator from that shape. Returns `nil` when the element decode fails or records nothing to synthesize (an element that would itself only pin).
private func discoverElementGenerator(
    _ elementType: any Decodable.Type,
    fromExample jsonValue: Any,
    codingPath: [any CodingKey]
) -> AnyGenerator? {
    func build<Element: Decodable>(_: Element.Type) -> AnyGenerator? {
        let decoder = DiscoveryDecoder(jsonValue: jsonValue, codingPath: codingPath)
        guard let representative = try? Element(from: decoder) else {
            return nil
        }
        let shape = decoder.shape
        guard shape.isEmpty == false else {
            return nil
        }
        return makeReconstructingGenerator(
            Element.self,
            shape: shape,
            pin: representative,
            codingPath: codingPath
        )
    }
    return build(elementType)
}

/// Builds an example-driven generator for a collection of a non-``ExhaustGenerable`` element type, or `nil` when `type` is not such a collection.
func makeDiscoveredCollectionGenerator(
    for type: Any.Type,
    fromExample jsonValue: Any,
    codingPath: [any CodingKey]
) -> AnyGenerator? {
    (type as? DiscoverableCollection.Type)?.discoveredGenerator(fromExample: jsonValue, codingPath: codingPath)
}
