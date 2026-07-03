import Exhaust
import ExhaustCore
import Foundation
import Testing

@Suite("Generator Synthesizer")
struct GeneratorSynthesizerTests {
    @Test("Synthesises a generator from a flat struct")
    func flatStruct() throws {
        let json = """
        {"name": "Gaute", "age": 30, "active": true}
        """
        let generator = try #gen(Person.self, from: json)
        let values = try #example(generator, count: 20)
        print()

        #expect(Set(values.map(\.name)).count > 1)
        #expect(Set(values.map(\.age)).count > 1)
    }

    @Test("Synthesises a generator from a nested struct")
    func nestedStruct() throws {
        let json = """
        {"name": "Bob", "address": {"street": "123 Main St", "city": "Springfield"}}
        """
        let data = json.data(using: .utf8)!
        let generator = try #gen(PersonWithAddress.self, from: data)
        let values = try #example(generator, count: 20)

        #expect(Set(values.map(\.name)).count > 1)
        #expect(Set(values.map(\.address.street)).count > 1)
        #expect(Set(values.map(\.address.city)).count > 1)
    }

    @Test("Generates all cases for CaseIterable enum properties")
    func caseIterableEnum() throws {
        let json = """
        {"label": "test", "status": "active"}
        """
        let generator = try #gen(WithEnum.self, from: json)
        let values = try #example(generator, count: 50)

        #expect(Set(values.map(\.label)).count > 1)
        #expect(Set(values.map(\.status)).count > 1)
    }

    @Test("Falls back to .just for non-CaseIterable RawRepresentable properties")
    func rawRepresentableFallback() throws {
        let json = """
        {"name": "test", "priority": "high"}
        """
        let generator = try #gen(WithNonIterable.self, from: json)
        let values = try #example(generator, count: 20)

        #expect(Set(values.map(\.name)).count > 1)
        #expect(values.allSatisfy { $0.priority == .high })
    }

    @Test("Exhaust finds a counterexample with a synthesised generator")
    func exhaustFindsCounterexample() throws {
        let json = """
        {"name": "Gaute", "age": 30, "active": true}
        """
        let generator = try #gen(Person.self, from: json)

        #exhaust(generator, .suppress(.issueReporting)) { person in
            person.age >= 0
        }
    }

    @Test("Generates dictionary properties")
    func dictionaryProperty() throws {
        let json = """
        {"name": "test", "scores": {"alice": 10, "bob": 20}}
        """
        let generator = try #gen(WithDictionary.self, from: json)
        let values = try #example(generator, count: 20, seed: 1337)

        #expect(Set(values.map(\.name)).count > 1)
        #expect(Set(values.map(\.scores.count)).count > 1)
    }

    @Test("Generates optional properties with both nil and non-nil values")
    func optionalProperty() throws {
        let json = """
        {"name": "Gaute", "nickname": "Ali"}
        """
        let generator = try #gen(WithOptional.self, from: json)
        let values = try #example(generator, count: 50)

        let nicknames = values.map(\.nickname)
        #expect(nicknames.contains(where: { $0 == nil }))
        #expect(nicknames.contains(where: { $0 != nil }))
    }

    @Test("Generates optional properties when JSON value is null")
    func optionalPropertyNull() throws {
        let json = """
        {"name": "Gaute", "nickname": null}
        """
        let generator = try #gen(WithOptional.self, from: json)
        let values = try #example(generator, count: 50)

        let nicknames = values.map(\.nickname)
        #expect(nicknames.contains(where: { $0 == nil }))
        #expect(nicknames.contains(where: { $0 != nil }))
    }

    @Test("Generates primitive optionals (Int, Double, Bool) with both nil and non-nil values")
    func primitiveOptionals() throws {
        // Synthesized Codable resolves `decodeIfPresent(Int.self, forKey:)` to the type-specific protocol requirement.
        // The replay container provides only the generic overload, so this exercises the standard library's default (`contains` + `decodeNil` + `decode`) for each primitive — the path that must stay correct now that the type-specific overloads are gone.
        let json = """
        {"name": "Gaute", "count": 7, "ratio": 0.25, "active": true}
        """
        let generator = try #gen(WithPrimitiveOptionals.self, from: json)
        let values = try #example(generator, count: 80)

        #expect(values.contains { $0.count == nil })
        #expect(values.contains { $0.count != nil })
        #expect(values.contains { $0.ratio == nil })
        #expect(values.contains { $0.ratio != nil })
        #expect(values.contains { $0.active == nil })
        #expect(values.contains { $0.active != nil })
    }

    @Test("Accepts a Codable instance directly")
    func codableInstance() throws {
        let example = Person(name: "Gaute", age: 30, active: true)
        let generator = try #gen(from: example)
        let values = try #example(generator, count: 20)
        print(generator.debugDescription)

        #expect(Set(values.map(\.name)).count > 1)
        #expect(Set(values.map(\.age)).count > 1)
    }

    @Test("Synthesised generators are marked with isSynthesised flag")
    func isSynthesisedFlag() throws {
        let json = """
        {"name": "Gaute", "age": 30, "active": true}
        """
        let synthesised = try #gen(Person.self, from: json)
        let handWritten = #gen(.int(in: 0 ... 100))

        #expect(synthesised.isSynthesized)
        #expect(handWritten.isSynthesized == false)
    }

    @Test("#examine skips reflection for synthesised generators")
    func examineSkipsReflection() throws {
        let json = """
        {"name": "Gaute", "age": 30, "active": true}
        """
        let generator = try #gen(Person.self, from: json)
        let report = #examine(generator, .budget(20))

        #expect(report.passed)
        #expect(report.valuesGenerated == 20)
        #expect(report.reflectionSkipped)
        #expect(report.pinnedFieldCount == 0)
    }

    @Test("#examine reports pinned fields for synthesised generators")
    func examineReportsPinnedFields() throws {
        let json = """
        {"name": "test", "priority": "high"}
        """
        let generator = try #gen(WithNonIterable.self, from: json)
        let report = #examine(generator, .budget(20))
        print()

        #expect(report.passed)
        #expect(report.pinnedFieldCount == 1)
    }

    @Test("Array field varies in length")
    func arrayConformance() throws {
        let gen = try #gen(ArrayOnly.self, from: """
        {"tags": ["a", "b"]}
        """)
        let values = try #example(gen, count: 50)
        #expect(Set(values.map(\.tags.count)).count > 1)
    }

    @Test("Dictionary field varies in size")
    func dictionaryConformance() throws {
        let gen = try #gen(DictionaryOnly.self, from: """
        {"scores": {"alice": 10, "bob": 20}}
        """)
        let values = try #example(gen, count: 50)
        #expect(Set(values.map(\.scores.count)).count > 1)
    }

    @Test("Set field varies in size")
    func setConformance() throws {
        let gen = try #gen(SetOnly.self, from: """
        {"ids": [1, 2, 3]}
        """)
        let values = try #example(gen, count: 50)
        #expect(Set(values.map(\.ids.count)).count > 1)
    }

    @Test("Nested Dictionary<String, [Int]> varies in size")
    func nestedDictionaryConformance() throws {
        let gen = try #gen(NestedDictionaryOnly.self, from: """
        {"metadata": {"key": [1, 2]}}
        """)
        let values = try #example(gen, count: 50)
        #expect(Set(values.map(\.metadata.count)).count > 1)
    }

    @Test("Doubly nested Dictionary<String, [String: [Int]]> varies in size")
    func doublyNestedDictionaryConformance() throws {
        let gen = try #gen(DoublyNestedDictionaryOnly.self, from: """
        {"deep": {"outer": {"inner": [1, 2]}}}
        """)
        let values = try #example(gen, count: 50)
        #expect(Set(values.map(\.deep.count)).count > 1)
    }

    @Test("Optional array produces both nil and non-nil")
    func optionalArrayConformance() throws {
        let gen = try #gen(OptionalArrayOnly.self, from: """
        {"tags": ["x"]}
        """)
        let values = try #example(gen, count: 50)
        #expect(values.contains(where: { $0.tags == nil }))
        #expect(values.contains(where: { $0.tags != nil }))
    }
}

// MARK: - Supporting Types

private struct Person: Codable, Equatable {
    let name: String
    let age: UInt
    let active: Bool
}

private struct Address: Codable, Equatable {
    let street: String
    let city: String
}

private struct PersonWithAddress: Codable, Equatable {
    let name: String
    let address: Address
}

private enum Status: String, Codable, CaseIterable {
    case active
    case inactive
}

private struct WithEnum: Codable {
    let label: String
    let status: Status
}

private enum Priority: String, Codable {
    case low
    case medium
    case high
}

private struct WithNonIterable: Codable {
    let name: String
    let priority: Priority
}

private struct WithDictionary: Codable {
    let name: String
    let scores: [String: Int]
}

private struct WithOptional: Codable {
    let name: String
    let nickname: String?
}

private struct ArrayOnly: Codable {
    let tags: [String]
}

private struct DictionaryOnly: Codable {
    let scores: [String: Int]
}

private struct SetOnly: Codable {
    let ids: Set<Int>
}

private struct NestedDictionaryOnly: Codable {
    let metadata: [String: [Int]]
}

private struct DoublyNestedDictionaryOnly: Codable {
    let deep: [String: [String: [Int]]]
}

private struct OptionalArrayOnly: Codable {
    let tags: [String]?
}

private struct WithPrimitiveOptionals: Codable {
    let name: String
    let count: Int?
    let ratio: Double?
    let active: Bool?
}
