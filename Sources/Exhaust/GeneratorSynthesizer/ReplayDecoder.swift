import Foundation

/// A `Decoder` that feeds pre-generated values through `init(from:)` to reconstruct a `Decodable` value.
///
/// Used inside the synthesized generator's `.map` closure. Each `decode` call pulls the next value from a sequential tape and casts it to the requested type.
package final class ReplayDecoder: Decoder {
    package let codingPath: [any CodingKey]
    package let userInfo: [CodingUserInfoKey: Any] = [:]
    private let values: [Any]
    private var index: Int = 0
    private var peekedValue: Any?

    package init(values: [Any], codingPath: [any CodingKey] = []) {
        self.values = values
        self.codingPath = codingPath
    }

    /// Consumes and returns the next value from the tape, or returns a previously peeked value.
    func nextValue() -> Any {
        if let peeked = peekedValue {
            peekedValue = nil
            return peeked
        }
        defer { index += 1 }
        return values[index]
    }

    /// Returns the next value without consuming it. A subsequent ``nextValue()`` call returns the same value.
    func peekValue() -> Any {
        let value = nextValue()
        peekedValue = value
        return value
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

    func decode<T: Decodable>(_: T.Type, forKey _: Key) throws -> T {
        decoder.nextValue() as! T
    }

    // Type-specific `decodeIfPresent` overloads — see DiscoveryDecoder.swift for why these are necessary. Each pulls a single value from the tape. Without these overrides, the protocol extension's default calls `decodeNil` then `decode`, consuming two tape values and crashing.

    func decodeIfPresent(_: Bool.Type, forKey _: Key) throws -> Bool? {
        decoder.nextValue() as? Bool
    }

    func decodeIfPresent(_: String.Type, forKey _: Key) throws -> String? {
        decoder.nextValue() as? String
    }

    func decodeIfPresent(_: Double.Type, forKey _: Key) throws -> Double? {
        decoder.nextValue() as? Double
    }

    func decodeIfPresent(_: Float.Type, forKey _: Key) throws -> Float? {
        decoder.nextValue() as? Float
    }

    func decodeIfPresent(_: Int.Type, forKey _: Key) throws -> Int? {
        decoder.nextValue() as? Int
    }

    func decodeIfPresent(_: Int8.Type, forKey _: Key) throws -> Int8? {
        decoder.nextValue() as? Int8
    }

    func decodeIfPresent(_: Int16.Type, forKey _: Key) throws -> Int16? {
        decoder.nextValue() as? Int16
    }

    func decodeIfPresent(_: Int32.Type, forKey _: Key) throws -> Int32? {
        decoder.nextValue() as? Int32
    }

    func decodeIfPresent(_: Int64.Type, forKey _: Key) throws -> Int64? {
        decoder.nextValue() as? Int64
    }

    func decodeIfPresent(_: UInt.Type, forKey _: Key) throws -> UInt? {
        decoder.nextValue() as? UInt
    }

    func decodeIfPresent(_: UInt8.Type, forKey _: Key) throws -> UInt8? {
        decoder.nextValue() as? UInt8
    }

    func decodeIfPresent(_: UInt16.Type, forKey _: Key) throws -> UInt16? {
        decoder.nextValue() as? UInt16
    }

    func decodeIfPresent(_: UInt32.Type, forKey _: Key) throws -> UInt32? {
        decoder.nextValue() as? UInt32
    }

    func decodeIfPresent(_: UInt64.Type, forKey _: Key) throws -> UInt64? {
        decoder.nextValue() as? UInt64
    }

    func decodeIfPresent<T: Decodable>(_: T.Type, forKey _: Key) throws -> T? {
        decoder.nextValue() as? T
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
        return decoder.nextValue() as! T
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
        decoder.nextValue() as! T
    }
}
