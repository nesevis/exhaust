import Foundation

/// A generated value, shaped per decoder level, that ``ReplayDecoder`` feeds through `init(from:)`.
///
/// Each value addresses one container level. A keyed level is a dictionary keyed by `CodingKey` string, so reconstruction reads each field by name rather than by position — a hand-written `init(from:)` that decodes fields in a different order than the example does still reads the right value. Nested types decoded through `decode(_:forKey:)` are already built by their own sub-generators and stored as ``leaf`` values; only `nestedContainer`-style decoding produces nested ``keyed``/``unkeyed`` values.
package indirect enum ReplayValue {
    /// A keyed container level: field values addressed by `CodingKey` string.
    case keyed([String: ReplayValue])
    /// An unkeyed container level: element values addressed by position, with a real count.
    case unkeyed([ReplayValue])
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

// MARK: - Replay Decoder

/// A `Decoder` that feeds a generated ``ReplayValue`` through `init(from:)` to reconstruct a `Decodable` value.
///
/// Used inside the synthesized generator's reconstruction map. Lookups are non-consuming and addressed by key or index; a key or index the generated value does not carry throws ``GenSchemaMiss``, which the synthesized generator catches to pin that sample to the example.
package final class ReplayDecoder: Decoder {
    package let codingPath: [any CodingKey]
    package let userInfo: [CodingUserInfoKey: Any] = [:]
    private let value: ReplayValue

    package init(_ value: ReplayValue, codingPath: [any CodingKey] = []) {
        self.value = value
        self.codingPath = codingPath
    }

    package func container<Key: CodingKey>(
        keyedBy _: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        guard case let .keyed(fields) = value else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        return KeyedDecodingContainer(
            ReplayKeyedContainer<Key>(fields: fields, codingPath: codingPath)
        )
    }

    package func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case let .unkeyed(elements) = value else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        return ReplayUnkeyedContainer(elements: elements, codingPath: codingPath)
    }

    package func singleValueContainer() throws -> any SingleValueDecodingContainer {
        ReplaySingleValueContainer(value: value, codingPath: codingPath)
    }
}

// MARK: - Keyed Container

private struct ReplayKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let fields: [String: ReplayValue]
    let codingPath: [any CodingKey]

    var allKeys: [Key] {
        fields.keys.compactMap { Key(stringValue: $0) }
    }

    func contains(_ key: Key) -> Bool {
        fields[key.stringValue] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        switch fields[key.stringValue] {
            case .none:
                return true
            case let .leaf(value):
                return leafIsNil(value)
            default:
                return false
        }
    }

    func decode<T: Decodable>(_: T.Type, forKey key: Key) throws -> T {
        guard case let .leaf(value)? = fields[key.stringValue], let typed = value as? T else {
            throw GenSchemaMiss(codingPath: codingPath + [key])
        }
        return typed
    }

    // No type-specific `decodeIfPresent` overloads, unlike the positional `DiscoveryDecoder`.
    // There, reading a value consumes the tape, so a missed overload desynchronizes; here lookups are key-addressed and non-consuming.
    // That lets the standard library's protocol-extension default — `contains(key) && !decodeNil(forKey:)` then `decode(_:forKey:)` — compose correctly for every primitive type.
    // Only the generic overload remains, for non-primitive optionals.

    func decodeIfPresent<T: Decodable>(_: T.Type, forKey key: Key) throws -> T? {
        guard case let .leaf(value)? = fields[key.stringValue] else {
            return nil
        }
        return value as? T
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        guard case let .keyed(nested)? = fields[key.stringValue] else {
            throw GenSchemaMiss(codingPath: codingPath + [key])
        }
        return KeyedDecodingContainer(
            ReplayKeyedContainer<NestedKey>(fields: nested, codingPath: codingPath + [key])
        )
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        guard case let .unkeyed(elements)? = fields[key.stringValue] else {
            throw GenSchemaMiss(codingPath: codingPath + [key])
        }
        return ReplayUnkeyedContainer(elements: elements, codingPath: codingPath + [key])
    }

    func superDecoder() throws -> any Decoder {
        ReplayDecoder(fields["super"] ?? .keyed([:]), codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        ReplayDecoder(fields[key.stringValue] ?? .keyed([:]), codingPath: codingPath + [key])
    }
}

// MARK: - Unkeyed Container

private struct ReplayUnkeyedContainer: UnkeyedDecodingContainer {
    let elements: [ReplayValue]
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
        guard isAtEnd == false, case let .keyed(nested) = elements[currentIndex] else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        currentIndex += 1
        return KeyedDecodingContainer(
            ReplayKeyedContainer<NestedKey>(fields: nested, codingPath: codingPath)
        )
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard isAtEnd == false, case let .unkeyed(nested) = elements[currentIndex] else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        currentIndex += 1
        return ReplayUnkeyedContainer(elements: nested, codingPath: codingPath)
    }

    mutating func superDecoder() throws -> any Decoder {
        guard isAtEnd == false else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        defer { currentIndex += 1 }
        return ReplayDecoder(elements[currentIndex], codingPath: codingPath)
    }
}

// MARK: - Single Value Container

private struct ReplaySingleValueContainer: SingleValueDecodingContainer {
    let value: ReplayValue
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
