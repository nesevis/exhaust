import Foundation

/// A `Decoder` that intercepts decode calls to build a generator tree while returning concrete JSON values.
package final class DiscoveryDecoder: Decoder {
    package let codingPath: [any CodingKey]
    package let userInfo: [CodingUserInfoKey: Any] = [:]
    private let jsonValue: Any
    package private(set) var childGenerators: [AnyGenerator] = []

    package init(jsonValue: Any, codingPath: [any CodingKey] = []) {
        self.jsonValue = jsonValue
        self.codingPath = codingPath
    }

    package func container<Key: CodingKey>(
        keyedBy _: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        guard let dictionary = jsonValue as? [String: Any] else {
            throw GeneratorSynthesizerError.unexpectedContainer
        }
        let container = DiscoveryKeyedContainer<Key>(
            dictionary: dictionary,
            decoder: self,
            codingPath: codingPath
        )
        return KeyedDecodingContainer(container)
    }

    package func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard let array = jsonValue as? [Any] else {
            throw GeneratorSynthesizerError.unexpectedContainer
        }
        return DiscoveryUnkeyedContainer(
            array: array,
            decoder: self,
            codingPath: codingPath
        )
    }

    package func singleValueContainer() throws -> any SingleValueDecodingContainer {
        DiscoverySingleValueContainer(
            value: jsonValue,
            decoder: self,
            codingPath: codingPath
        )
    }

    func recordGenerator(_ generator: AnyGenerator) {
        childGenerators.append(generator)
    }
}

// MARK: - Keyed Container

private struct DiscoveryKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let dictionary: [String: Any]
    let decoder: DiscoveryDecoder
    let codingPath: [any CodingKey]

    var allKeys: [Key] {
        dictionary.keys.compactMap { Key(stringValue: $0) }
    }

    func contains(_ key: Key) -> Bool {
        dictionary[key.stringValue] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let value = dictionary[key.stringValue] else { return true }
        return value is NSNull
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let jsonValue = dictionary[key.stringValue] as Any
        let decodedValue = try decodeValue(type, from: jsonValue, key: key)
        recordGeneratorForType(type, decodedValue: decodedValue, jsonValue: jsonValue, key: key, asOptional: false)
        return decodedValue
    }

    // MARK: - decodeIfPresent — Type-Specific Overloads

    //
    // `KeyedDecodingContainerProtocol` declares type-specific `decodeIfPresent` methods for each primitive type (Bool, String, Double, Float, Int, Int8...Int64, UInt, UInt8...UInt64) as separate protocol requirements alongside the generic `decodeIfPresent<T: Decodable>`.
    //
    // This is a Swift 4 design that predates conditional conformances and existential types. Each primitive needed its own protocol requirement so concrete decoders could dispatch to type-specific parsing logic (for example, NSNumber → Int vs NSNumber → Double). Today you would design it as a single generic method, but it is baked into the standard library ABI.
    //
    // When synthesized Codable calls `decodeIfPresent(String.self, forKey:)`, the compiler resolves to the String-specific overload, not the generic one. The type-erased `KeyedDecodingContainer` box forwards to whichever overload the concrete container provides. If only the generic overload is overridden, the String-specific call hits the protocol extension's default implementation, which calls `decodeNil` then `decode` — consuming two values from the replay tape instead of one, causing an index-out-of-range crash.
    //
    // Types not listed here (Date, UUID, URL, Data, and all other Decodable types) go through the generic overload, which we also override.

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? {
        try decodeOptional(type, forKey: key)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        try decodeOptional(type, forKey: key)
    }

    private func decodeOptional<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        let jsonValue = dictionary[key.stringValue]
        let isNil = jsonValue == nil || jsonValue is NSNull
        let decodedValue: T? = isNil ? nil : try decodeValue(type, from: jsonValue as Any, key: key)
        recordGeneratorForType(type, decodedValue: decodedValue, jsonValue: jsonValue as Any, key: key, asOptional: true)
        return decodedValue
    }

    private func recordGeneratorForType<T: Decodable>(
        _ type: T.Type,
        decodedValue: T?,
        jsonValue: Any,
        key: Key,
        asOptional: Bool
    ) {
        let generator: AnyGenerator

        if let collectionGen = makeCollectionGenerator(for: type) {
            generator = collectionGen
        } else if let generableType = type as? ExhaustGenerable.Type {
            generator = generableType.defaultGenerator
        } else if let caseIterable = type as? any(CaseIterable & Decodable).Type {
            generator = makeCaseIterableGenerator(caseIterable)
        } else if type is any RawRepresentable.Type {
            generator = Gen.just((decodedValue ?? jsonValue) as Any).erase()
        } else {
            let nested = DiscoveryDecoder(
                jsonValue: jsonValue,
                codingPath: codingPath + [key]
            )
            if (try? T(from: nested)) != nil,
               nested.childGenerators.isEmpty == false
            {
                let childGens = ContiguousArray(nested.childGenerators)
                let zipped: AnyGenerator = .impure(
                    operation: .zip(childGens),
                    continuation: { .pure($0) }
                )
                let pinnedFallback = (decodedValue ?? jsonValue) as Any
                let fallbackPath = codingPath + [key]
                generator = Gen.liftF(.transform(
                    kind: .map(
                        forward: { values in
                            // Pin this nested value to the example if a generated value reaches an
                            // uncovered branch in `T.init(from:)`, rather than crashing the whole sample.
                            do {
                                let replay = ReplayDecoder(values: values as! [Any])
                                return try T(from: replay) as Any
                            } catch is GenSchemaMiss {
                                SynthesisDiagnostics.recordFallback(type: T.self, codingPath: fallbackPath)
                                return pinnedFallback
                            }
                        },
                        inputType: [Any].self,
                        outputType: Any.self
                    ),
                    inner: zipped
                )) as AnyGenerator
            } else {
                generator = Gen.just((decodedValue ?? jsonValue) as Any).erase()
            }
        }

        decoder.recordGenerator(asOptional ? wrapOptional(generator) : generator)
    }

    private func decodeValue<T: Decodable>(_ type: T.Type, from jsonValue: Any, key: Key) throws -> T {
        if type is any ExhaustGenerable.Type, let primitive = try? decodePrimitive(type, from: jsonValue) {
            return primitive
        }
        let nested = DiscoveryDecoder(jsonValue: jsonValue, codingPath: codingPath + [key])
        return try T(from: nested)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        guard let nested = dictionary[key.stringValue] as? [String: Any] else {
            throw GeneratorSynthesizerError.unexpectedContainer
        }
        let container = DiscoveryKeyedContainer<NestedKey>(
            dictionary: nested,
            decoder: decoder,
            codingPath: codingPath + [key]
        )
        return KeyedDecodingContainer(container)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        guard let array = dictionary[key.stringValue] as? [Any] else {
            throw GeneratorSynthesizerError.unexpectedContainer
        }
        return DiscoveryUnkeyedContainer(
            array: array,
            decoder: decoder,
            codingPath: codingPath + [key]
        )
    }

    func superDecoder() throws -> any Decoder {
        DiscoveryDecoder(
            jsonValue: dictionary["super"] as Any,
            codingPath: codingPath
        )
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        DiscoveryDecoder(
            jsonValue: dictionary[key.stringValue] as Any,
            codingPath: codingPath + [key]
        )
    }
}

// MARK: - Unkeyed Container

private struct DiscoveryUnkeyedContainer: UnkeyedDecodingContainer {
    let array: [Any]
    let decoder: DiscoveryDecoder
    let codingPath: [any CodingKey]
    var count: Int? {
        array.count
    }

    var isAtEnd: Bool {
        currentIndex >= array.count
    }

    var currentIndex: Int = 0

    mutating func decodeNil() throws -> Bool {
        guard isAtEnd == false else { return true }
        if array[currentIndex] is NSNull {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard isAtEnd == false else {
            throw DecodingError.valueNotFound(
                type,
                .init(codingPath: codingPath, debugDescription: "Unkeyed container exhausted")
            )
        }
        let jsonValue = array[currentIndex]
        currentIndex += 1

        if let generableType = type as? ExhaustGenerable.Type {
            decoder.recordGenerator(generableType.defaultGenerator)
            return try decodePrimitive(type, from: jsonValue)
        }

        let nested = DiscoveryDecoder(jsonValue: jsonValue, codingPath: codingPath)
        return try T(from: nested)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        guard isAtEnd == false,
              let dict = array[currentIndex] as? [String: Any]
        else {
            throw GeneratorSynthesizerError.unexpectedContainer
        }
        currentIndex += 1
        let container = DiscoveryKeyedContainer<NestedKey>(
            dictionary: dict,
            decoder: decoder,
            codingPath: codingPath
        )
        return KeyedDecodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard isAtEnd == false,
              let nestedArray = array[currentIndex] as? [Any]
        else {
            throw GeneratorSynthesizerError.unexpectedContainer
        }
        currentIndex += 1
        return DiscoveryUnkeyedContainer(
            array: nestedArray,
            decoder: decoder,
            codingPath: codingPath
        )
    }

    mutating func superDecoder() throws -> any Decoder {
        DiscoveryDecoder(jsonValue: array, codingPath: codingPath)
    }
}

// MARK: - Single Value Container

private struct DiscoverySingleValueContainer: SingleValueDecodingContainer {
    let value: Any
    let decoder: DiscoveryDecoder
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool {
        value is NSNull
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if let generableType = type as? ExhaustGenerable.Type {
            decoder.recordGenerator(generableType.defaultGenerator)
            return try decodePrimitive(type, from: value)
        }

        let nested = DiscoveryDecoder(jsonValue: value, codingPath: codingPath)
        return try T(from: nested)
    }
}

// MARK: - Primitive Decoding

private func wrapOptional(_ innerGenerator: AnyGenerator) -> AnyGenerator {
    // Wrap using the public `.optional()` generator so default weights stay consistent
    ReflectiveGenerator(innerGenerator, isSynthesized: true).optional().gen.erase()
}

private func makeCaseIterableGenerator(_ type: any (CaseIterable & Decodable).Type) -> AnyGenerator {
    func build<T: CaseIterable & Decodable>(_: T.Type) -> AnyGenerator {
        let cases = Array(T.allCases)
        precondition(cases.isEmpty == false, "CaseIterable type \(T.self) has no cases")
        return Gen.pick(
            choices: cases.map { (1, Gen.just($0 as Any)) }
        ).erase()
    }
    return build(type)
}

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
private func resolveGenerator(for type: Any.Type) -> AnyGenerator? {
    if let generable = type as? ExhaustGenerable.Type {
        return generable.defaultGenerator
    }
    if let collection = type as? SynthesizableCollection.Type {
        return collection.synthesizedGenerator
    }
    return nil
}

private func makeCollectionGenerator(for type: (some Any).Type) -> AnyGenerator? {
    (type as? SynthesizableCollection.Type)?.synthesizedGenerator
}

private func decodePrimitive<T>(_ type: T.Type, from jsonValue: Any) throws -> T {
    if let value = jsonValue as? T {
        return value
    }
    if type == Bool.self, let number = jsonValue as? NSNumber {
        return number.boolValue as! T
    }
    if type == Int.self, let number = jsonValue as? NSNumber {
        return number.intValue as! T
    }
    if type == Int8.self, let number = jsonValue as? NSNumber {
        return number.int8Value as! T
    }
    if type == Int16.self, let number = jsonValue as? NSNumber {
        return number.int16Value as! T
    }
    if type == Int32.self, let number = jsonValue as? NSNumber {
        return number.int32Value as! T
    }
    if type == Int64.self, let number = jsonValue as? NSNumber {
        return number.int64Value as! T
    }
    if type == UInt.self, let number = jsonValue as? NSNumber {
        return number.uintValue as! T
    }
    if type == UInt8.self, let number = jsonValue as? NSNumber {
        return number.uint8Value as! T
    }
    if type == UInt16.self, let number = jsonValue as? NSNumber {
        return number.uint16Value as! T
    }
    if type == UInt32.self, let number = jsonValue as? NSNumber {
        return number.uint32Value as! T
    }
    if type == UInt64.self, let number = jsonValue as? NSNumber {
        return number.uint64Value as! T
    }
    if type == Float.self, let number = jsonValue as? NSNumber {
        return number.floatValue as! T
    }
    if type == Double.self, let number = jsonValue as? NSNumber {
        return number.doubleValue as! T
    }
    if type == String.self, let string = jsonValue as? String {
        return string as! T
    }
    throw DecodingError.typeMismatch(
        type,
        .init(codingPath: [], debugDescription: "Cannot decode \(type) from \(Swift.type(of: jsonValue))")
    )
}
