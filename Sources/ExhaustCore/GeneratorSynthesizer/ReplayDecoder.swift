import Foundation

/// A `Decoder` that feeds pre-generated values through `init(from:)` to reconstruct a `Decodable` value.
///
/// Used inside the synthesized generator's `.map` closure. Each `decode` call pulls the next value from a sequential tape and casts it to the requested type.
package final class ReplayDecoder: Decoder {
    package let codingPath: [any CodingKey]
    package let userInfo: [CodingUserInfoKey: Any] = [:]
    private let values: [Any]
    private var index: Int = 0

    package init(values: [Any], codingPath: [any CodingKey] = []) {
        self.values = values
        self.codingPath = codingPath
    }

    /// Consumes and returns the next value from the tape.
    ///
    /// Throws ``GenSchemaMiss`` rather than trapping when the tape is exhausted. Exhaustion means a generated value drove `init(from:)` to decode more values than the discovery pass recorded — the synthesized generator catches this and pins the affected value to the example.
    ///
    /// - Parameter codingPath: The coding path of the requesting decode call, recorded on the thrown ``GenSchemaMiss``.
    func nextValue(at codingPath: [any CodingKey]) throws -> Any {
        guard index < values.count else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        defer { index += 1 }
        return values[index]
    }

    package func container<Key: CodingKey>(
        keyedBy _: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(
            ReplayKeyedContainer<Key>(decoder: self, codingPath: codingPath)
        )
    }

    package func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        ReplayUnkeyedContainer(decoder: self, codingPath: codingPath)
    }

    package func singleValueContainer() throws -> any SingleValueDecodingContainer {
        ReplaySingleValueContainer(decoder: self, codingPath: codingPath)
    }
}

// MARK: - Keyed Container

private struct ReplayKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: ReplayDecoder
    let codingPath: [any CodingKey]
    var allKeys: [Key] {
        []
    }

    func contains(_: Key) -> Bool {
        true
    }

    func decodeNil(forKey _: Key) throws -> Bool {
        false
    }

    func decode<T: Decodable>(_: T.Type, forKey key: Key) throws -> T {
        let value = try decoder.nextValue(at: codingPath + [key])
        guard let typed = value as? T else {
            throw GenSchemaMiss(codingPath: codingPath + [key])
        }
        return typed
    }

    // Type-specific `decodeIfPresent` overloads — see DiscoveryDecoder.swift for why these are necessary. Each pulls a single value from the tape. Without these overrides, the protocol extension's default calls `decodeNil` then `decode`, consuming two tape values and crashing.

    func decodeIfPresent(_: Bool.Type, forKey key: Key) throws -> Bool? {
        try decoder.nextValue(at: codingPath + [key]) as? Bool
    }

    func decodeIfPresent(_: String.Type, forKey key: Key) throws -> String? {
        try decoder.nextValue(at: codingPath + [key]) as? String
    }

    func decodeIfPresent(_: Double.Type, forKey key: Key) throws -> Double? {
        try decoder.nextValue(at: codingPath + [key]) as? Double
    }

    func decodeIfPresent(_: Float.Type, forKey key: Key) throws -> Float? {
        try decoder.nextValue(at: codingPath + [key]) as? Float
    }

    func decodeIfPresent(_: Int.Type, forKey key: Key) throws -> Int? {
        try decoder.nextValue(at: codingPath + [key]) as? Int
    }

    func decodeIfPresent(_: Int8.Type, forKey key: Key) throws -> Int8? {
        try decoder.nextValue(at: codingPath + [key]) as? Int8
    }

    func decodeIfPresent(_: Int16.Type, forKey key: Key) throws -> Int16? {
        try decoder.nextValue(at: codingPath + [key]) as? Int16
    }

    func decodeIfPresent(_: Int32.Type, forKey key: Key) throws -> Int32? {
        try decoder.nextValue(at: codingPath + [key]) as? Int32
    }

    func decodeIfPresent(_: Int64.Type, forKey key: Key) throws -> Int64? {
        try decoder.nextValue(at: codingPath + [key]) as? Int64
    }

    func decodeIfPresent(_: UInt.Type, forKey key: Key) throws -> UInt? {
        try decoder.nextValue(at: codingPath + [key]) as? UInt
    }

    func decodeIfPresent(_: UInt8.Type, forKey key: Key) throws -> UInt8? {
        try decoder.nextValue(at: codingPath + [key]) as? UInt8
    }

    func decodeIfPresent(_: UInt16.Type, forKey key: Key) throws -> UInt16? {
        try decoder.nextValue(at: codingPath + [key]) as? UInt16
    }

    func decodeIfPresent(_: UInt32.Type, forKey key: Key) throws -> UInt32? {
        try decoder.nextValue(at: codingPath + [key]) as? UInt32
    }

    func decodeIfPresent(_: UInt64.Type, forKey key: Key) throws -> UInt64? {
        try decoder.nextValue(at: codingPath + [key]) as? UInt64
    }

    func decodeIfPresent<T: Decodable>(_: T.Type, forKey key: Key) throws -> T? {
        try decoder.nextValue(at: codingPath + [key]) as? T
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        KeyedDecodingContainer(
            ReplayKeyedContainer<NestedKey>(decoder: decoder, codingPath: codingPath + [key])
        )
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        ReplayUnkeyedContainer(decoder: decoder, codingPath: codingPath + [key])
    }

    func superDecoder() throws -> any Decoder {
        decoder
    }

    func superDecoder(forKey _: Key) throws -> any Decoder {
        decoder
    }
}

// MARK: - Unkeyed Container

private struct ReplayUnkeyedContainer: UnkeyedDecodingContainer {
    let decoder: ReplayDecoder
    let codingPath: [any CodingKey]
    var count: Int? {
        nil
    }

    var isAtEnd: Bool {
        false
    }

    var currentIndex: Int = 0

    mutating func decodeNil() throws -> Bool {
        false
    }

    mutating func decode<T: Decodable>(_: T.Type) throws -> T {
        currentIndex += 1
        let value = try decoder.nextValue(at: codingPath)
        guard let typed = value as? T else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        return typed
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        KeyedDecodingContainer(
            ReplayKeyedContainer<NestedKey>(decoder: decoder, codingPath: codingPath)
        )
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        ReplayUnkeyedContainer(decoder: decoder, codingPath: codingPath)
    }

    mutating func superDecoder() throws -> any Decoder {
        decoder
    }
}

// MARK: - Single Value Container

private struct ReplaySingleValueContainer: SingleValueDecodingContainer {
    let decoder: ReplayDecoder
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool {
        false
    }

    func decode<T: Decodable>(_: T.Type) throws -> T {
        let value = try decoder.nextValue(at: codingPath)
        guard let typed = value as? T else {
            throw GenSchemaMiss(codingPath: codingPath)
        }
        return typed
    }
}
