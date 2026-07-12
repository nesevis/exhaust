// Byte-level round-tripping of choice sequences for the progress log.

import Foundation

/// Serialises choice sequences to compact opaque strings for the progress log.
///
/// The durable record is the choice sequence — bit patterns and structural markers only, nothing tied to a particular build. The byte stream is versioned so a format change invalidates old logs cleanly (decode returns nil, the log is ignored) instead of misreading them.
package enum ChoiceSequenceCodec {
    /// Bumped on any change to the byte layout below.
    private static let formatVersion: UInt8 = 1

    private enum Kind: UInt8 {
        case groupOpen = 0
        case groupClose = 1
        case sequenceOpen = 2
        case sequenceClose = 3
        case bindOpen = 4
        case bindClose = 5
        case just = 6
        case branch = 7
        case value = 8
    }

    // MARK: - Encoding

    /// Encodes a sequence to a base64 string.
    package static func encode(_ sequence: ChoiceSequence) -> String {
        var bytes: [UInt8] = [formatVersion]
        bytes.reserveCapacity(1 + sequence.count * 12)
        for entry in sequence {
            switch entry {
                case .group(true):
                    bytes.append(Kind.groupOpen.rawValue)
                case .group(false):
                    bytes.append(Kind.groupClose.rawValue)
                case let .sequence(isOpen, validRange, isLengthExplicit):
                    bytes.append(isOpen ? Kind.sequenceOpen.rawValue : Kind.sequenceClose.rawValue)
                    appendRange(validRange, to: &bytes)
                    bytes.append(isLengthExplicit ? 1 : 0)
                case .bind(true):
                    bytes.append(Kind.bindOpen.rawValue)
                case .bind(false):
                    bytes.append(Kind.bindClose.rawValue)
                case .just:
                    bytes.append(Kind.just.rawValue)
                case let .branch(branch):
                    bytes.append(Kind.branch.rawValue)
                    appendUInt64(branch.id, to: &bytes)
                    appendUInt64(branch.branchCount, to: &bytes)
                    appendUInt64(branch.fingerprint, to: &bytes)
                case let .value(value):
                    bytes.append(Kind.value.rawValue)
                    appendUInt64(value.choice.bitPattern64, to: &bytes)
                    bytes.append(value.choice.tag.rawValue)
                    appendRange(value.validRange, to: &bytes)
                    bytes.append(value.isRangeExplicit ? 1 : 0)
            }
        }
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Decoding

    /// Decodes a sequence from a base64 string, or nil when the payload is malformed or from a different format version.
    package static func decode(_ encoded: String) -> ChoiceSequence? {
        guard let data = Data(base64Encoded: encoded) else {
            return nil
        }
        let bytes = [UInt8](data)
        var cursor = 0
        guard readUInt8(bytes, &cursor) == formatVersion else {
            return nil
        }

        var sequence = ChoiceSequence()
        while cursor < bytes.count {
            guard let kindByte = readUInt8(bytes, &cursor), let kind = Kind(rawValue: kindByte) else {
                return nil
            }
            switch kind {
                case .groupOpen:
                    sequence.append(.group(true))
                case .groupClose:
                    sequence.append(.group(false))
                case .sequenceOpen, .sequenceClose:
                    guard let range = readRange(bytes, &cursor), let explicitFlag = readUInt8(bytes, &cursor) else {
                        return nil
                    }
                    sequence.append(.sequence(
                        kind == .sequenceOpen,
                        validRange: range,
                        isLengthExplicit: explicitFlag == 1
                    ))
                case .bindOpen:
                    sequence.append(.bind(true))
                case .bindClose:
                    sequence.append(.bind(false))
                case .just:
                    sequence.append(.just)
                case .branch:
                    guard let id = readUInt64(bytes, &cursor),
                          let branchCount = readUInt64(bytes, &cursor),
                          let fingerprint = readUInt64(bytes, &cursor)
                    else {
                        return nil
                    }
                    sequence.append(.branch(ChoiceSequenceValue.Branch(
                        id: id,
                        branchCount: branchCount,
                        fingerprint: fingerprint
                    )))
                case .value:
                    guard let bitPattern = readUInt64(bytes, &cursor),
                          let tagByte = readUInt8(bytes, &cursor),
                          let tag = TypeTag(rawValue: tagByte),
                          let range = readRange(bytes, &cursor),
                          let explicitFlag = readUInt8(bytes, &cursor)
                    else {
                        return nil
                    }
                    sequence.append(.value(ChoiceSequenceValue.Value(
                        choice: ChoiceValue(bitPattern, tag: tag),
                        validRange: range,
                        isRangeExplicit: explicitFlag == 1
                    )))
            }
        }
        return sequence
    }

    // MARK: - Primitives

    private static func appendUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { buffer in
            bytes.append(contentsOf: buffer)
        }
    }

    private static func appendRange(_ range: ClosedRange<UInt64>?, to bytes: inout [UInt8]) {
        if let range {
            bytes.append(1)
            appendUInt64(range.lowerBound, to: &bytes)
            appendUInt64(range.upperBound, to: &bytes)
        } else {
            bytes.append(0)
        }
    }

    private static func readUInt8(_ bytes: [UInt8], _ cursor: inout Int) -> UInt8? {
        guard cursor < bytes.count else {
            return nil
        }
        defer {
            cursor += 1
        }
        return bytes[cursor]
    }

    private static func readUInt64(_ bytes: [UInt8], _ cursor: inout Int) -> UInt64? {
        guard cursor + 8 <= bytes.count else {
            return nil
        }
        var value: UInt64 = 0
        for offset in (0 ..< 8).reversed() {
            value = value << 8 | UInt64(bytes[cursor + offset])
        }
        cursor += 8
        return value
    }

    /// Reads an optional range. The outer optional is nil on malformed input; the inner value is nil when the flag byte marked absence.
    private static func readRange(_ bytes: [UInt8], _ cursor: inout Int) -> ClosedRange<UInt64>?? {
        guard let flag = readUInt8(bytes, &cursor) else {
            return nil
        }
        guard flag == 1 else {
            return .some(nil)
        }
        guard let lower = readUInt64(bytes, &cursor), let upper = readUInt64(bytes, &cursor), lower <= upper else {
            return nil
        }
        return lower ... upper
    }
}
