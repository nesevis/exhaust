import Exhaust
import Foundation
import Testing

/// Regression tests for synthesizer crash-proofing: a custom `init(from:)` that reaches an uncovered branch pins to the example instead of trapping, and top-level leaf and collection types resolve to real generators instead of crashing or throwing.
@Suite("Generator Synthesizer — crash safety")
struct GeneratorSynthesizerCrashSafetyTests {
    /// The example covers only the short branch, so a generated value that takes the long branch exhausts the tape. That now pins to the example for the affected sample, so every value is the example's branch and nothing crashes.
    @Test("Custom branching init pins instead of crashing")
    func branchingInitPinsInsteadOfCrashing() throws {
        let generator = try #gen(Conditional.self, from: """
        {"kind": false}
        """)
        let values = try #example(generator, count: 50)

        #expect(values.count == 50)
        #expect(values.allSatisfy { $0.kind == false })
        #expect(values.allSatisfy { $0.payload == nil })
    }

    /// A top-level array of a non-ExhaustGenerable element discovers the element type from a representative element of the example, so the array varies in both length and contents rather than pinning to the example.
    @Test("Top-level collection of non-generable elements varies in length and contents")
    func topLevelStructArrayVaries() throws {
        let generator = try #gen([Member].self, from: """
        [{"id": 1}, {"id": 2}]
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.count)).count > 1)
        #expect(Set(values.flatMap { $0.map(\.id) }).count > 1)
    }

    /// A top-level array of a generable element resolves through root dispatch to the standard array generator, so the length varies like a hand-written `[Int]`.
    @Test("Top-level array of generable elements varies in length")
    func topLevelIntArrayVaries() throws {
        let generator = try #gen([Int].self, from: """
        [1, 2, 3]
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.count)).count > 1)
    }

    /// A top-level single-value type resolves through root dispatch to its pre-configured generator, rather than throwing at synthesis or recording the wrong inner primitive.
    @Test("Top-level Date resolves to a varying generator")
    func topLevelDateVaries() throws {
        let generator = try #gen(Date.self, from: "0")
        let values = try #example(generator, count: 50)

        #expect(Set(values).count > 1)
    }

    /// Same for UUID.
    @Test("Top-level UUID resolves to a varying generator")
    func topLevelUUIDVaries() throws {
        let generator = try #gen(UUID.self, from: "\"00000000-0000-0000-0000-000000000000\"")
        let values = try #example(generator, count: 50)

        #expect(Set(values).count > 1)
    }

    /// A `CaseIterable` enum with no cases has nothing to pick from; the discovery pass falls through to a pin instead of trapping in `Gen.pick`.
    @Test("Empty-allCases enum field pins instead of crashing")
    func emptyCaseIterableEnumPins() throws {
        let generator = try #gen(WithEmptyEnum.self, from: """
        {"name": "x", "marker": null}
        """)
        let values = try #example(generator, count: 20)

        #expect(values.count == 20)
        #expect(values.allSatisfy { $0.marker == nil })
    }
}

/// Regression tests for key-addressed replay: a value reads its field by `CodingKey`, so a custom `init(from:)` that decodes fields in a different order on different branches still reads the right value rather than swapping or pinning.
@Suite("Generator Synthesizer — key addressing")
struct GeneratorSynthesizerKeyAddressingTests {
    /// The example takes the `flag == true` branch, recording fields in the order `flag, a, b`. A generated `flag == false` decodes `b` before `a`. With positional replay this read the wrong tape slot (and pinned to the example, which has `flag == true`); with key addressing each field reads its own value, so the `false` branch produces real, varied values.
    @Test("Reordered-branch init reads fields by key, not position")
    func reorderedBranchReadsByKey() throws {
        let generator = try #gen(ReorderedBranch.self, from: """
        {"flag": true, "a": 42, "b": "hello"}
        """)
        let values = try #example(generator, count: 50)

        // The false branch is reachable and not pinned to the (flag == true) example.
        #expect(values.contains { $0.flag == true })
        #expect(values.contains { $0.flag == false })
        // Both fields vary independently — neither is swapped nor frozen.
        #expect(Set(values.map(\.a)).count > 1)
        #expect(Set(values.map(\.b)).count > 1)
    }
}

/// Regression tests for collection-element recursion: a collection of a non-ExhaustGenerable struct discovers its element type from a representative example element and varies in length and contents, rather than pinning the whole collection to the example.
@Suite("Generator Synthesizer — collection element recursion")
struct GeneratorSynthesizerCollectionTests {
    @Test("Nested array of a non-generable struct varies")
    func nestedStructArrayVaries() throws {
        let generator = try #gen(Team.self, from: """
        {"name": "Avengers", "members": [{"id": 1}, {"id": 2}]}
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.members.count)).count > 1)
        #expect(Set(values.flatMap { $0.members.map(\.id) }).count > 1)
    }

    @Test("Set of a non-generable struct varies in size")
    func structSetVaries() throws {
        let generator = try #gen(ShapeBag.self, from: """
        {"shapes": [{"id": 1}, {"id": 2}]}
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.shapes.count)).count > 1)
    }

    @Test("Dictionary with non-generable struct values varies in size")
    func structDictionaryVaries() throws {
        let generator = try #gen(Catalog.self, from: """
        {"items": {"a": {"id": 1}, "b": {"id": 2}}}
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.items.count)).count > 1)
    }
}

/// Regression tests for inline nested containers: a custom `init(from:)` that decodes a nested structure with `nestedContainer(keyedBy:forKey:)` or `nestedUnkeyedContainer(forKey:)` records the nested fields as a sub-tree, so they vary rather than pinning.
@Suite("Generator Synthesizer — nested containers")
struct GeneratorSynthesizerNestedContainerTests {
    @Test("Inline nested keyed container varies outer and nested fields")
    func inlineNestedKeyedContainerVaries() throws {
        let generator = try #gen(InlineNested.self, from: """
        {"id": 1, "meta": {"label": "hello"}}
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.id)).count > 1)
        #expect(Set(values.map(\.label)).count > 1)
    }

    @Test("Inline nested unkeyed container varies its length and elements")
    func inlineNestedUnkeyedContainerVaries() throws {
        let generator = try #gen(InlineList.self, from: """
        {"id": 1, "numbers": [10, 20, 30]}
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.id)).count > 1)
        #expect(Set(values.map(\.numbers.count)).count > 1)
        #expect(Set(values.flatMap(\.numbers)).count > 1)
    }
}

/// Regression tests for unkeyed element discovery: a custom `init(from:)` that decodes non-`ExhaustGenerable` types from an unkeyed container records each element's generator, so the shape reflects all positions and every field varies.
@Suite("Generator Synthesizer — unkeyed non-primitive elements")
struct SynthesizerUnkeyedElementTests {
    @Test("Non-primitive elements decoded from an unkeyed container are recorded and vary")
    func unkeyedNonPrimitiveElementVaries() throws {
        let generator = try #gen(TaggedRecord.self, from: """
        ["purchase", {"item": "Socks", "quantity": 3}]
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.tag)).count > 1)
        #expect(Set(values.map(\.detail.item)).count > 1)
    }
}

/// Regression tests for keyed `superDecoder()` discovery: a class hierarchy whose subclass calls `superDecoder()` on a keyed container folds the superclass fields into the parent shape, so both subclass and superclass fields vary.
@Suite("Generator Synthesizer — superDecoder discovery")
struct SynthesizerSuperDecoderTests {
    @Test("Fields decoded through superDecoder() are folded into the parent shape and vary")
    func superDecoderFieldsVary() throws {
        let generator = try #gen(Hound.self, from: """
        {"breed": "Labrador", "super": {"name": "Rex", "legs": 4}}
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.breed)).count > 1)
        #expect(Set(values.map(\.name)).count > 1)
    }
}

/// Regression tests for single-value element discovery: a newtype wrapper that decodes a non-`ExhaustGenerable` type through a single-value container records the inner type's generator, so the wrapper varies instead of pinning.
@Suite("Generator Synthesizer — single-value non-primitive")
struct SynthesizerSingleValueTests {
    @Test("Non-primitive type decoded through a single-value container varies")
    func singleValueNonPrimitiveVaries() throws {
        let generator = try #gen(WrappedPayload.self, from: """
        {"item": "Socks", "quantity": 3}
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.payload.item)).count > 1)
    }
}

/// Regression tests for unkeyed `superDecoder()` discovery: a class hierarchy whose subclass calls `superDecoder()` on an unkeyed container reads the current array element, advances the index, and folds the superclass shape into the parent.
@Suite("Generator Synthesizer — unkeyed superDecoder")
struct SynthesizerUnkeyedSuperTests {
    @Test("Fields decoded through unkeyed superDecoder() vary")
    func unkeyedSuperDecoderFieldsVary() throws {
        let generator = try #gen(UnkeyedChild.self, from: """
        ["Alice", {"id": "42"}]
        """)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.name)).count > 1)
        #expect(Set(values.map(\.id)).count > 1)
    }
}

// MARK: - Supporting Types

private struct Member: Codable, Hashable {
    let id: Int
}

private enum NoCases: CaseIterable, Codable {
    case unused
    static var allCases: [NoCases] {
        []
    }
}

private struct WithEmptyEnum: Codable {
    let name: String
    let marker: NoCases?
}

private struct Team: Codable {
    let name: String
    let members: [Member]
}

private struct ShapeBag: Codable {
    let shapes: Set<Member>
}

private struct Catalog: Codable {
    let items: [String: Member]
}

private struct Conditional: Codable {
    let kind: Bool
    let payload: Int?

    enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Bool.self, forKey: .kind)
        if kind {
            payload = try container.decode(Int.self, forKey: .payload)
        } else {
            payload = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(payload, forKey: .payload)
    }
}

private struct ReorderedBranch: Codable, Equatable {
    let flag: Bool
    let a: Int
    let b: String

    enum CodingKeys: String, CodingKey {
        case flag
        case a
        case b
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flag = try container.decode(Bool.self, forKey: .flag)
        if flag {
            a = try container.decode(Int.self, forKey: .a)
            b = try container.decode(String.self, forKey: .b)
        } else {
            b = try container.decode(String.self, forKey: .b)
            a = try container.decode(Int.self, forKey: .a)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(flag, forKey: .flag)
        try container.encode(a, forKey: .a)
        try container.encode(b, forKey: .b)
    }
}

private struct InlineNested: Decodable {
    let id: Int
    let label: String

    enum CodingKeys: String, CodingKey {
        case id
        case meta
    }

    enum MetaKeys: String, CodingKey {
        case label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        let meta = try container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
        label = try meta.decode(String.self, forKey: .label)
    }
}

private struct InlineList: Decodable {
    let id: Int
    let numbers: [Int]

    enum CodingKeys: String, CodingKey {
        case id
        case numbers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        var nested = try container.nestedUnkeyedContainer(forKey: .numbers)
        var collected = [Int]()
        while nested.isAtEnd == false {
            try collected.append(nested.decode(Int.self))
        }
        numbers = collected
    }
}

private struct Payload: Codable, Equatable {
    let item: String
    let quantity: Int
}

private struct TaggedRecord: Decodable {
    let tag: String
    let detail: Payload

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        tag = try container.decode(String.self)
        detail = try container.decode(Payload.self)
    }
}

private class Animal: Decodable {
    let name: String
    let legs: Int
}

private final class Hound: Animal {
    let breed: String

    enum CodingKeys: String, CodingKey {
        case breed
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        breed = try container.decode(String.self, forKey: .breed)
        try super.init(from: container.superDecoder())
    }
}

private struct WrappedPayload: Decodable {
    let payload: Payload

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        payload = try container.decode(Payload.self)
    }
}

private class UnkeyedBase: Decodable {
    let id: String
}

private final class UnkeyedChild: UnkeyedBase {
    let name: String

    required init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        name = try container.decode(String.self)
        try super.init(from: container.superDecoder())
    }
}
