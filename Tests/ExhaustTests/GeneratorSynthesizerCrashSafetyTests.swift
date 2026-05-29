import Exhaust
import ExhaustCore
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
        let values = #example(generator, count: 50)

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
        let values = #example(generator, count: 50)

        #expect(Set(values.map(\.count)).count > 1)
        #expect(Set(values.flatMap { $0.map(\.id) }).count > 1)
    }

    /// A top-level array of a generable element resolves through root dispatch to the standard array generator, so the length varies like a hand-written `[Int]`.
    @Test("Top-level array of generable elements varies in length")
    func topLevelIntArrayVaries() throws {
        let generator = try #gen([Int].self, from: """
        [1, 2, 3]
        """)
        let values = #example(generator, count: 50)

        #expect(Set(values.map(\.count)).count > 1)
    }

    /// A top-level single-value type resolves through root dispatch to its pre-configured generator, rather than throwing at synthesis or recording the wrong inner primitive.
    @Test("Top-level Date resolves to a varying generator")
    func topLevelDateVaries() throws {
        let generator = try #gen(Date.self, from: "0")
        let values = #example(generator, count: 50)

        #expect(Set(values).count > 1)
    }

    /// Same for UUID.
    @Test("Top-level UUID resolves to a varying generator")
    func topLevelUUIDVaries() throws {
        let generator = try #gen(UUID.self, from: "\"00000000-0000-0000-0000-000000000000\"")
        let values = #example(generator, count: 50)

        #expect(Set(values).count > 1)
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
        let values = #example(generator, count: 50)

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
        let values = #example(generator, count: 50)

        #expect(Set(values.map(\.members.count)).count > 1)
        #expect(Set(values.flatMap { $0.members.map(\.id) }).count > 1)
    }

    @Test("Set of a non-generable struct varies in size")
    func structSetVaries() throws {
        let generator = try #gen(ShapeBag.self, from: """
        {"shapes": [{"id": 1}, {"id": 2}]}
        """)
        let values = #example(generator, count: 50)

        #expect(Set(values.map(\.shapes.count)).count > 1)
    }

    @Test("Dictionary with non-generable struct values varies in size")
    func structDictionaryVaries() throws {
        let generator = try #gen(Catalog.self, from: """
        {"items": {"a": {"id": 1}, "b": {"id": 2}}}
        """)
        let values = #example(generator, count: 50)

        #expect(Set(values.map(\.items.count)).count > 1)
    }
}

// MARK: - Supporting Types

private struct Member: Codable, Hashable {
    let id: Int
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
