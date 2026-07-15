import Foundation

/// A `Decoder` that intercepts decode calls to record a per-level generator shape while returning concrete JSON values.
package final class DiscoveryDecoder: Decoder {
    package let codingPath: [any CodingKey]
    package let userInfo: [CodingUserInfoKey: Any] = [:]
    private let jsonValue: Any

    // The keyed/unkeyed/single fields are populated by whichever container kind the decoded type requested; `nestedDecoders` holds the sub-decoders spawned for inline `nestedContainer(forKey:)` calls on a keyed container. The `shape` getter resolves them into a `ContainerShape`.
    private var keyedChildren: [(key: String, generator: AnyGenerator, isOptional: Bool)] = []
    private var unkeyedEntries: [UnkeyedEntry] = []
    private var singleChild: AnyGenerator?
    private var nestedDecoders: [(key: String, decoder: DiscoveryDecoder)] = []
    private var observedUnkeyedCollectionTraversal = false

    package init(jsonValue: Any, codingPath: [any CodingKey] = []) {
        self.jsonValue = jsonValue
        self.codingPath = codingPath
    }

    /// The container shape discovered for this decoder's value.
    ///
    /// A keyed level combines its direct field generators with the sub-shapes of any inline nested containers, each folded in under its key as a child whose generator produces a nested ``ReplayValue``. Reading this after `init(from:)` completes is what gives the nested decoders their final shape.
    package var shape: ContainerShape {
        if let singleChild {
            return .single(singleChild)
        }
        if keyedChildren.isEmpty == false || nestedDecoders.isEmpty == false {
            var children = keyedChildren.map {
                KeyedChild(key: $0.key, generator: $0.generator, producesReplayValue: false, isOptional: $0.isOptional)
            }
            for (key, nestedDecoder) in nestedDecoders {
                children.append(KeyedChild(
                    key: key,
                    generator: nestedReplayValueGenerator(for: nestedDecoder.shape),
                    producesReplayValue: true,
                    isOptional: false
                ))
            }
            return .keyed(children)
        }
        if unkeyedEntries.isEmpty == false {
            var elements: [UnkeyedElement] = []
            var elementTypes = Set<ObjectIdentifier>()
            var hasNested = false

            for entry in unkeyedEntries {
                switch entry {
                    case let .element(elementType, generator):
                        elementTypes.insert(elementType)
                        elements.append(UnkeyedElement(generator: generator, producesReplayValue: false))
                    case let .nested(decoder):
                        hasNested = true
                        elements.append(UnkeyedElement(
                            generator: nestedReplayValueGenerator(for: decoder.shape),
                            producesReplayValue: true
                        ))
                }
            }

            // A single element type across all positions with no nested decoders reads as a collection (a loop over homogeneous elements), so the length varies. Mixed types or nested decoders read as a positional/tuple decode that wants exactly this sequence, so the length stays fixed.
            if observedUnkeyedCollectionTraversal, hasNested == false, elementTypes.count == 1 {
                return .homogeneousArray(element: elements[0].generator)
            }
            return .unkeyed(elements)
        }
        return .empty
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

    func recordKeyed(_ key: String, _ generator: AnyGenerator, isOptional: Bool) {
        keyedChildren.append((key, generator, isOptional))
    }

    func recordUnkeyed(elementType: Any.Type, _ generator: AnyGenerator) {
        unkeyedEntries.append(.element(elementType: ObjectIdentifier(elementType), generator: generator))
    }

    func recordUnkeyedNested(decoder: DiscoveryDecoder) {
        unkeyedEntries.append(.nested(decoder: decoder))
    }

    func recordUnkeyedCollectionTraversal() {
        observedUnkeyedCollectionTraversal = true
    }

    func recordSingle(_ generator: AnyGenerator) {
        singleChild = generator
    }

    func recordNested(key: String, decoder: DiscoveryDecoder) {
        nestedDecoders.append((key, decoder))
    }
}

private enum UnkeyedEntry {
    case element(elementType: ObjectIdentifier, generator: AnyGenerator)
    case nested(decoder: DiscoveryDecoder)
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

        // Collections are checked before `ExhaustGenerable` because Array/Dictionary/Set conform to `ExhaustGenerable` only conditionally, and those conditional conformance records are not reliably linked in xcframework builds. `SynthesizableCollection` and `DiscoverableCollection` are unconditional, so they resolve where the conditional conformance would not.
        if let collectionGenerator = (type as? SynthesizableCollection.Type)?.synthesizedGenerator {
            generator = collectionGenerator
        } else if let discoveredCollectionGenerator = makeDiscoveredCollectionGenerator(
            for: type,
            fromExample: jsonValue,
            codingPath: codingPath + [key]
        ) {
            generator = discoveredCollectionGenerator
        } else if let generableType = type as? ExhaustGenerable.Type {
            generator = generableType.defaultGenerator
        } else if let caseIterable = type as? any(CaseIterable & Decodable).Type,
                  let caseGenerator = makeCaseIterableGenerator(caseIterable)
        {
            generator = caseGenerator
        } else if type is any RawRepresentable.Type {
            generator = Gen.just((decodedValue ?? jsonValue) as Any).erase()
        } else {
            // Recurse into the nested type. Use the recorded shape only when the example decode succeeds — a partial shape from a thrown decode would reconstruct from incomplete fields. An empty shape (decode failed, or produced no leaves) makes `makeReconstructingGenerator` pin to the example, so no separate branch is needed.
            let nested = DiscoveryDecoder(jsonValue: jsonValue, codingPath: codingPath + [key])
            let shape = (try? T(from: nested)) == nil ? ContainerShape.empty : nested.shape
            generator = makeReconstructingGenerator(
                type,
                shape: shape,
                pin: (decodedValue ?? jsonValue) as Any,
                codingPath: codingPath + [key]
            )
        }

        decoder.recordKeyed(key.stringValue, asOptional ? wrapOptional(generator) : generator, isOptional: asOptional)
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
        // A fresh decoder keeps the nested container's recordings separate from this level's, so its shape folds in under `key` as a nested `ReplayValue` rather than flattening into this level's fields.
        let nestedDecoder = DiscoveryDecoder(jsonValue: nested, codingPath: codingPath + [key])
        decoder.recordNested(key: key.stringValue, decoder: nestedDecoder)
        let container = DiscoveryKeyedContainer<NestedKey>(
            dictionary: nested,
            decoder: nestedDecoder,
            codingPath: codingPath + [key]
        )
        return KeyedDecodingContainer(container)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        guard let array = dictionary[key.stringValue] as? [Any] else {
            throw GeneratorSynthesizerError.unexpectedContainer
        }
        let nestedDecoder = DiscoveryDecoder(jsonValue: array, codingPath: codingPath + [key])
        decoder.recordNested(key: key.stringValue, decoder: nestedDecoder)
        return DiscoveryUnkeyedContainer(
            array: array,
            decoder: nestedDecoder,
            codingPath: codingPath + [key]
        )
    }

    func superDecoder() throws -> any Decoder {
        let nested = DiscoveryDecoder(
            jsonValue: dictionary["super"] as Any,
            codingPath: codingPath
        )
        decoder.recordNested(key: "super", decoder: nested)
        return nested
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        let nested = DiscoveryDecoder(
            jsonValue: dictionary[key.stringValue] as Any,
            codingPath: codingPath + [key]
        )
        decoder.recordNested(key: key.stringValue, decoder: nested)
        return nested
    }
}

// MARK: - Unkeyed Container

private struct DiscoveryUnkeyedContainer: UnkeyedDecodingContainer {
    let array: [Any]
    let decoder: DiscoveryDecoder
    let codingPath: [any CodingKey]
    var count: Int? {
        decoder.recordUnkeyedCollectionTraversal()
        return array.count
    }

    var isAtEnd: Bool {
        decoder.recordUnkeyedCollectionTraversal()
        return currentIndex >= array.count
    }

    var currentIndex: Int = 0

    mutating func decodeNil() throws -> Bool {
        guard currentIndex < array.count else { return true }
        if array[currentIndex] is NSNull {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard currentIndex < array.count else {
            throw DecodingError.valueNotFound(
                type,
                .init(codingPath: codingPath, debugDescription: "Unkeyed container exhausted")
            )
        }
        let jsonValue = array[currentIndex]
        currentIndex += 1

        if let generableType = type as? ExhaustGenerable.Type,
           let primitive = try? decodePrimitive(type, from: jsonValue)
        {
            decoder.recordUnkeyed(elementType: type, generableType.defaultGenerator)
            return primitive
        }

        let nested = DiscoveryDecoder(jsonValue: jsonValue, codingPath: codingPath)
        let decodedValue = try T(from: nested)

        let generator: AnyGenerator
        if let collectionGenerator = (type as? SynthesizableCollection.Type)?.synthesizedGenerator {
            generator = collectionGenerator
        } else if let discoveredCollectionGenerator = makeDiscoveredCollectionGenerator(
            for: type,
            fromExample: jsonValue,
            codingPath: codingPath
        ) {
            generator = discoveredCollectionGenerator
        } else if let generableType = type as? ExhaustGenerable.Type {
            generator = generableType.defaultGenerator
        } else if let caseIterable = type as? any(CaseIterable & Decodable).Type,
                  let caseGenerator = makeCaseIterableGenerator(caseIterable)
        {
            generator = caseGenerator
        } else if type is any RawRepresentable.Type {
            generator = Gen.just(decodedValue as Any).erase()
        } else {
            generator = makeReconstructingGenerator(
                type,
                shape: nested.shape,
                pin: decodedValue as Any,
                codingPath: codingPath
            )
        }

        decoder.recordUnkeyed(elementType: type, generator)
        return decodedValue
    }

    // A nested container opened inside an unkeyed container records into the *parent* unkeyed decoder — there is no fresh sub-decoder here, unlike the keyed `nestedContainer(forKey:)` path. For a hand-written init that decodes structs element-by-element this leaves the parent level with keyed/unkeyed children that do not match the unkeyed container the parent's `init(from:)` reopens at replay, so the value degrades to a pin rather than reconstructing. This is the documented "manual element-by-element unkeyed decoding" limitation.

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        guard currentIndex < array.count,
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
        guard currentIndex < array.count,
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
        guard currentIndex < array.count else {
            throw DecodingError.valueNotFound(
                Any.self,
                .init(codingPath: codingPath, debugDescription: "Unkeyed container exhausted")
            )
        }
        let nested = DiscoveryDecoder(
            jsonValue: array[currentIndex],
            codingPath: codingPath
        )
        currentIndex += 1
        decoder.recordUnkeyedNested(decoder: nested)
        return nested
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
        if let generableType = type as? ExhaustGenerable.Type,
           let primitive = try? decodePrimitive(type, from: value)
        {
            decoder.recordSingle(generableType.defaultGenerator)
            return primitive
        }

        let nested = DiscoveryDecoder(jsonValue: value, codingPath: codingPath)
        let decodedValue = try T(from: nested)

        let generator: AnyGenerator
        if let collectionGenerator = (type as? SynthesizableCollection.Type)?.synthesizedGenerator {
            generator = collectionGenerator
        } else if let discoveredCollectionGenerator = makeDiscoveredCollectionGenerator(
            for: type,
            fromExample: value,
            codingPath: codingPath
        ) {
            generator = discoveredCollectionGenerator
        } else if let generableType = type as? ExhaustGenerable.Type {
            generator = generableType.defaultGenerator
        } else if let caseIterable = type as? any(CaseIterable & Decodable).Type,
                  let caseGenerator = makeCaseIterableGenerator(caseIterable)
        {
            generator = caseGenerator
        } else if type is any RawRepresentable.Type {
            generator = Gen.just(decodedValue as Any).erase()
        } else {
            generator = makeReconstructingGenerator(
                type,
                shape: nested.shape,
                pin: decodedValue as Any,
                codingPath: codingPath
            )
        }

        decoder.recordSingle(generator)
        return decodedValue
    }
}

// MARK: - Primitive Decoding

private func decodePrimitive<T: Decodable>(_ type: T.Type, from jsonValue: Any) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: jsonValue, options: .fragmentsAllowed)
    return try JSONDecoder().decode(type, from: data)
}
