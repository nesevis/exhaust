import Foundation

/// A generated value, shaped per decoder level, that ``ExampleDecoder`` feeds through `init(from:)`.
///
/// Each value addresses one container level. A keyed level is a dictionary keyed by `CodingKey` string, so reconstruction reads each field by name rather than by position — a hand-written `init(from:)` that decodes fields in a different order than the example does still reads the right value. Nested types decoded through `decode(_:forKey:)` are already built by their own sub-generators and stored as ``leaf`` values; only `nestedContainer`-style decoding produces nested ``keyed``/``unkeyed`` values.
package enum ExampleValue {
    /// A keyed container level: field values addressed by `CodingKey` string.
    case keyed([String: ExampleValue])
    /// A keyed container level with positional metadata from the discovery pass. Field values are addressed by cursor with a lazy dictionary fallback for out-of-order `init(from:)` implementations.
    case positionalKeyed(keys: [String], values: [Any], producesExampleValue: [Bool], isOptional: [Bool])
    /// An unkeyed container level: element values addressed by position, with a real count.
    case unkeyed([ExampleValue])
    /// An unkeyed container level whose elements are raw values rather than ``ExampleValue`` wrappers.
    case rawUnkeyed([Any])
    /// A single generated (or pre-built) value. A nil optional is `leaf` wrapping `Optional.none`.
    case leaf(Any)
}

// MARK: - Optional detection

//
// A nil optional is stored as `leaf(Optional<Any>.none)`. `as?` already unwraps it correctly for `decode`/`decodeIfPresent`, so the only place that needs to recognize it is `decodeNil`. A protocol cast avoids the cost of `Mirror` on this path.

private protocol OptionalValue {
    var isNilValue: Bool { get }
}

extension Optional: OptionalValue {
    var isNilValue: Bool {
        self == nil
    }
}

private func leafIsNil(_ value: Any) -> Bool {
    (value as? OptionalValue)?.isNilValue ?? false
}

// MARK: - Keyed Example State

final class KeyedExampleState {
    let keys: [String]
    let producesExampleValue: [Bool]
    let isOptional: [Bool]
    var values: [Any] = []
    var position: Int = 0
    var fallback: [String: Int]?

    init(keys: [String], producesExampleValue: [Bool], isOptional: [Bool]) {
        self.keys = keys
        self.producesExampleValue = producesExampleValue
        self.isOptional = isOptional
    }

    func reset(values: [Any]) {
        self.values = values
        position = 0
    }
}

// MARK: - Example Decoder

/// A `Decoder` that feeds a generated ``ExampleValue`` through `init(from:)` to reconstruct a `Decodable` value.
///
/// Used inside the synthesized generator's reconstruction map. Lookups are non-consuming and addressed by key or index; a key or index the generated value does not carry throws ``GenSchemaMiss``, which the synthesized generator catches to pin that sample to the example.
package final class ExampleDecoder: Decoder {
    package let codingPath: [any CodingKey]
    package let userInfo: [CodingUserInfoKey: Any] = [:]
    private let value: ExampleValue
    private let replayState: KeyedExampleState?
    private var cachedKeyedContainer: Any?

    package init(_ value: ExampleValue, codingPath: [any CodingKey] = []) {
        self.value = value
        self.codingPath = codingPath
        replayState = nil
    }

    init(reusableState: KeyedExampleState, codingPath: [any CodingKey]) {
        value = .leaf(())
        replayState = reusableState
        self.codingPath = codingPath
    }

    package func container<Key: CodingKey>(
        keyedBy _: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        if let state = replayState {
            if let cached = cachedKeyedContainer as? KeyedDecodingContainer<Key> {
                return cached
            }
            let container = KeyedDecodingContainer(
                ExampleKeyedContainer<Key>(state: state, codingPath: codingPath)
            )
            cachedKeyedContainer = container
            return container
        }

        switch value {
            case let .keyed(fields):
                return KeyedDecodingContainer(
                    ExampleKeyedContainer<Key>(dictionary: fields, codingPath: codingPath)
                )
            case let .positionalKeyed(keys, values, producesExampleValue, isOptional):
                let state = KeyedExampleState(
                    keys: keys,
                    producesExampleValue: producesExampleValue,
                    isOptional: isOptional
                )
                state.values = values
                return KeyedDecodingContainer(
                    ExampleKeyedContainer<Key>(state: state, codingPath: codingPath)
                )
            default:
                throw GenSchemaMiss(codingPath: codingPath)
        }
    }

    package func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        switch value {
            case let .unkeyed(elements):
                return ExampleUnkeyedContainer(elements: elements, codingPath: codingPath)
            case let .rawUnkeyed(elements):
                return ExampleRawUnkeyedContainer(elements: elements, codingPath: codingPath)
            default:
                throw GenSchemaMiss(codingPath: codingPath)
        }
    }

    package func singleValueContainer() throws -> any SingleValueDecodingContainer {
        ExampleSingleValueContainer(value: value, codingPath: codingPath)
    }
}

// MARK: - Keyed Container

private struct ExampleKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    private enum Storage {
        case positional(KeyedExampleState)
        case dictionary([String: ExampleValue])
    }

    private let storage: Storage
    let codingPath: [any CodingKey]

    init(state: KeyedExampleState, codingPath: [any CodingKey]) {
        storage = .positional(state)
        self.codingPath = codingPath
    }

    init(dictionary: [String: ExampleValue], codingPath: [any CodingKey]) {
        storage = .dictionary(dictionary)
        self.codingPath = codingPath
    }

    var allKeys: [Key] {
        switch storage {
            case let .positional(state):
                state.keys.compactMap { Key(stringValue: $0) }
            case let .dictionary(fields):
                fields.keys.compactMap { Key(stringValue: $0) }
        }
    }

    func contains(_ key: Key) -> Bool {
        switch storage {
            case let .positional(state):
                findIndex(forKey: key, in: state) != nil
            case let .dictionary(fields):
                fields[key.stringValue] != nil
        }
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        switch storage {
            case let .positional(state):
                guard let index = findIndex(forKey: key, in: state) else {
                    return true
                }
                if state.isOptional[index] == false {
                    return false
                }
                return leafIsNil(state.values[index])
            case let .dictionary(fields):
                switch fields[key.stringValue] {
                    case .none:
                        return true
                    case let .leaf(value):
                        return leafIsNil(value)
                    default:
                        return false
                }
        }
    }

    func decode<T: Decodable>(_: T.Type, forKey key: Key) throws -> T {
        switch storage {
            case let .positional(state):
                guard let index = findIndex(forKey: key, in: state),
                      state.producesExampleValue[index] == false,
                      let typed = state.values[index] as? T
                else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                advanceCursor(state, past: index)
                return typed
            case let .dictionary(fields):
                guard case let .leaf(value)? = fields[key.stringValue], let typed = value as? T else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                return typed
        }
    }

    // MARK: - decodeIfPresent — Type-Specific Overloads

    //
    // `KeyedDecodingContainerProtocol` declares type-specific `decodeIfPresent` for each primitive type as separate protocol requirements. The compiler-synthesized `init(from:)` dispatches to these type-specific overloads, not the generic one. Without explicit overloads, the protocol-extension default composes as `contains` + `decodeNil` + `decode` — three lookups per optional field. Each overload here collapses that to a single lookup.

    func decodeIfPresent(_: Bool.Type, forKey key: Key) throws -> Bool? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: String.Type, forKey key: Key) throws -> String? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: Double.Type, forKey key: Key) throws -> Double? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: Float.Type, forKey key: Key) throws -> Float? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: Int.Type, forKey key: Key) throws -> Int? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: Int8.Type, forKey key: Key) throws -> Int8? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: Int16.Type, forKey key: Key) throws -> Int16? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: Int32.Type, forKey key: Key) throws -> Int32? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: Int64.Type, forKey key: Key) throws -> Int64? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: UInt.Type, forKey key: Key) throws -> UInt? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: UInt8.Type, forKey key: Key) throws -> UInt8? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: UInt16.Type, forKey key: Key) throws -> UInt16? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: UInt32.Type, forKey key: Key) throws -> UInt32? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent(_: UInt64.Type, forKey key: Key) throws -> UInt64? {
        try resolveOptionalPrimitive(forKey: key)
    }

    func decodeIfPresent<T: Decodable>(_: T.Type, forKey key: Key) throws -> T? {
        try resolveOptional(forKey: key)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        switch storage {
            case let .positional(state):
                guard let index = findIndex(forKey: key, in: state),
                      state.producesExampleValue[index],
                      let nested = state.values[index] as? ExampleValue
                else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                advanceCursor(state, past: index)
                return try ExampleDecoder(nested, codingPath: codingPath + [key]).container(keyedBy: type)
            case let .dictionary(fields):
                guard case let .keyed(nested)? = fields[key.stringValue] else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                return KeyedDecodingContainer(
                    ExampleKeyedContainer<NestedKey>(dictionary: nested, codingPath: codingPath + [key])
                )
        }
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        switch storage {
            case let .positional(state):
                guard let index = findIndex(forKey: key, in: state),
                      state.producesExampleValue[index],
                      let nested = state.values[index] as? ExampleValue
                else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                advanceCursor(state, past: index)
                return try ExampleDecoder(nested, codingPath: codingPath + [key]).unkeyedContainer()
            case let .dictionary(fields):
                guard case let .unkeyed(elements)? = fields[key.stringValue] else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                return ExampleUnkeyedContainer(elements: elements, codingPath: codingPath + [key])
        }
    }

    func superDecoder() throws -> any Decoder {
        switch storage {
            case let .positional(state):
                if let index = findIndex(forKeyString: "super", in: state),
                   let nested = state.values[index] as? ExampleValue
                {
                    advanceCursor(state, past: index)
                    return ExampleDecoder(nested, codingPath: codingPath)
                }
                return ExampleDecoder(.keyed([:]), codingPath: codingPath)
            case let .dictionary(fields):
                return ExampleDecoder(fields["super"] ?? .keyed([:]), codingPath: codingPath)
        }
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        switch storage {
            case let .positional(state):
                if let index = findIndex(forKey: key, in: state),
                   let nested = state.values[index] as? ExampleValue
                {
                    advanceCursor(state, past: index)
                    return ExampleDecoder(nested, codingPath: codingPath + [key])
                }
                return ExampleDecoder(.keyed([:]), codingPath: codingPath + [key])
            case let .dictionary(fields):
                return ExampleDecoder(fields[key.stringValue] ?? .keyed([:]), codingPath: codingPath + [key])
        }
    }
}

// MARK: - Keyed Container Helpers

extension ExampleKeyedContainer {
    private func findIndex(forKey key: some CodingKey, in state: KeyedExampleState) -> Int? {
        findIndex(forKeyString: key.stringValue, in: state)
    }

    private func findIndex(forKeyString keyString: String, in state: KeyedExampleState) -> Int? {
        let position = state.position
        if position < state.keys.count, state.keys[position] == keyString {
            return position
        }
        if state.fallback == nil {
            var map = [String: Int](minimumCapacity: state.keys.count)
            for (index, storedKey) in state.keys.enumerated() {
                map[storedKey] = index
            }
            state.fallback = map
        }
        return state.fallback![keyString]
    }

    private func advanceCursor(_ state: KeyedExampleState, past index: Int) {
        if index == state.position {
            state.position = index + 1
        }
    }

    private func resolveOptionalPrimitive<T>(forKey key: Key) throws -> T? {
        switch storage {
            case let .positional(state):
                guard let index = findIndex(forKey: key, in: state) else {
                    return nil
                }
                advanceCursor(state, past: index)
                if state.producesExampleValue[index] {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                let value = state.values[index]
                if state.isOptional[index], leafIsNil(value) {
                    return nil
                }
                guard let typed = value as? T else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                return typed
            case let .dictionary(fields):
                guard let entry = fields[key.stringValue] else {
                    return nil
                }
                switch entry {
                    case let .leaf(value):
                        if leafIsNil(value) {
                            return nil
                        }
                        guard let typed = value as? T else {
                            throw GenSchemaMiss(codingPath: codingPath + [key])
                        }
                        return typed
                    default:
                        throw GenSchemaMiss(codingPath: codingPath + [key])
                }
        }
    }

    private func resolveOptional<T>(forKey key: Key) throws -> T? {
        switch storage {
            case let .positional(state):
                guard let index = findIndex(forKey: key, in: state) else {
                    return nil
                }
                advanceCursor(state, past: index)
                guard state.producesExampleValue[index] == false else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                let value = state.values[index]
                if state.isOptional[index], leafIsNil(value) {
                    return nil
                }
                guard let typed = value as? T else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                return typed
            case let .dictionary(fields):
                guard let entry = fields[key.stringValue] else {
                    return nil
                }
                guard case let .leaf(value) = entry else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                if leafIsNil(value) {
                    return nil
                }
                guard let typed = value as? T else {
                    throw GenSchemaMiss(codingPath: codingPath + [key])
                }
                return typed
        }
    }
}

// MARK: - Unkeyed Container

private struct ExampleUnkeyedContainer: UnkeyedDecodingContainer {
    let elements: [ExampleValue]
    let codingPath: [any CodingKey]
    var currentIndex: Int = 0

    var count: Int? {
        elements.count
    }

    var isAtEnd: Bool {
        currentIndex >= elements.count
    }

    mutating func decodeNil() throws -> Bool {
        guard isAtEnd == false, case let .leaf(value) = elements[currentIndex], leafIsNil(value) else {
            return false
        }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_: T.Type) throws -> T {
        guard isAtEnd == false, case let .leaf(value) = elements[currentIndex], let typed = value as? T else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        currentIndex += 1
        return typed
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        guard isAtEnd == false else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        let element = elements[currentIndex]
        currentIndex += 1
        switch element {
            case let .keyed(nested):
                return KeyedDecodingContainer(
                    ExampleKeyedContainer<NestedKey>(dictionary: nested, codingPath: codingPath)
                )
            case let .positionalKeyed(keys, values, producesExampleValue, isOptional):
                let state = KeyedExampleState(
                    keys: keys,
                    producesExampleValue: producesExampleValue,
                    isOptional: isOptional
                )
                state.values = values
                return KeyedDecodingContainer(
                    ExampleKeyedContainer<NestedKey>(state: state, codingPath: codingPath)
                )
            default:
                throw GenSchemaMiss(codingPath: codingPath)
        }
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard isAtEnd == false else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        let element = elements[currentIndex]
        currentIndex += 1
        switch element {
            case let .unkeyed(nested):
                return ExampleUnkeyedContainer(elements: nested, codingPath: codingPath)
            case let .rawUnkeyed(nested):
                return ExampleRawUnkeyedContainer(elements: nested, codingPath: codingPath)
            default:
                throw GenSchemaMiss(codingPath: codingPath)
        }
    }

    mutating func superDecoder() throws -> any Decoder {
        guard isAtEnd == false else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        defer { currentIndex += 1 }
        return ExampleDecoder(elements[currentIndex], codingPath: codingPath)
    }
}

// MARK: - Raw Unkeyed Container

private struct ExampleRawUnkeyedContainer: UnkeyedDecodingContainer {
    let elements: [Any]
    let codingPath: [any CodingKey]
    var currentIndex: Int = 0

    var count: Int? {
        elements.count
    }

    var isAtEnd: Bool {
        currentIndex >= elements.count
    }

    mutating func decodeNil() throws -> Bool {
        guard isAtEnd == false, leafIsNil(elements[currentIndex]) else {
            return false
        }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_: T.Type) throws -> T {
        guard isAtEnd == false, let typed = elements[currentIndex] as? T else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        currentIndex += 1
        return typed
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw GenSchemaMiss(codingPath: codingPath)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw GenSchemaMiss(codingPath: codingPath)
    }

    mutating func superDecoder() throws -> any Decoder {
        throw GenSchemaMiss(codingPath: codingPath)
    }
}

// MARK: - Single Value Container

private struct ExampleSingleValueContainer: SingleValueDecodingContainer {
    let value: ExampleValue
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool {
        guard case let .leaf(inner) = value else {
            return false
        }
        return leafIsNil(inner)
    }

    func decode<T: Decodable>(_: T.Type) throws -> T {
        guard case let .leaf(inner) = value, let typed = inner as? T else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        return typed
    }
}
