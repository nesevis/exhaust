import Exhaust
import ExhaustCore
import Foundation
import Testing

/// Regression tests for synthesizer crash-proofing: a custom `init(from:)` that reaches an
/// uncovered branch pins to the example instead of trapping, and top-level leaf and collection
/// types resolve to real generators instead of crashing or throwing.
@Suite("Generator Synthesizer — crash safety")
struct GeneratorSynthesizerCrashSafetyTests {
    /// The example covers only the short branch, so a generated value that takes the long branch
    /// exhausts the tape. That now pins to the example for the affected sample, so every value is
    /// the example's branch and nothing crashes.
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

    /// A top-level array of a non-ExhaustGenerable element records no child generators, so the
    /// replay tape is empty and the unkeyed container's loop used to over-read and trap. It now
    /// pins to the example.
    @Test("Top-level collection of non-generable elements pins instead of crashing")
    func topLevelStructArrayPins() throws {
        let generator = try #gen([Member].self, from: """
        [{"id": 1}, {"id": 2}]
        """)
        let values = #example(generator, count: 20)

        #expect(values.count == 20)
        #expect(values.allSatisfy { $0 == [Member(id: 1), Member(id: 2)] })
    }

    /// A top-level array of a generable element resolves through root dispatch to the standard
    /// array generator, so the length varies like a hand-written `[Int]`.
    @Test("Top-level array of generable elements varies in length")
    func topLevelIntArrayVaries() throws {
        let generator = try #gen([Int].self, from: """
        [1, 2, 3]
        """)
        let values = #example(generator, count: 50)

        #expect(Set(values.map(\.count)).count > 1)
    }

    /// A top-level single-value type resolves through root dispatch to its pre-configured
    /// generator, rather than throwing at synthesis or recording the wrong inner primitive.
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

// MARK: - Supporting Types

private struct Member: Codable, Equatable {
    let id: Int
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
