import Exhaust
import ExhaustCore
import Foundation
import Testing

@Suite("FuzzyDecoder")
struct FuzzyDecoderTests {
    @Test("Synthesises a generator from a flat struct")
    func flatStruct() throws {
        let json = """
        {"name": "Gaute", "age": 30, "active": true}
        """
        let generator = try #gen(Person.self, from: json)
        let values = #example(generator, count: 20)
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
        let values = #example(generator, count: 20)

        #expect(Set(values.map(\.name)).count > 1)
        #expect(Set(values.map(\.address.street)).count > 1)
        #expect(Set(values.map(\.address.city)).count > 1)
    }

    @Test("Generates all cases for CaseIterable enum properties")
    func caseIterableEnum() {
        let json = """
        {"label": "test", "status": "active"}
        """
        let generator = #gen(WithEnum.self, from: json)
        let values = #example(generator, count: 50)

        #expect(Set(values.map(\.label)).count > 1)
        #expect(Set(values.map(\.status)).count > 1)
    }

    @Test("Falls back to .just for non-CaseIterable RawRepresentable properties")
    func rawRepresentableFallback() {
        let json = """
        {"name": "test", "priority": "high"}
        """
        let generator = #gen(WithNonIterable.self, from: json)
        let values = #example(generator, count: 20)

        #expect(Set(values.map(\.name)).count > 1)
        #expect(values.allSatisfy { $0.priority == .high })
    }

    @Test("Exhaust finds a counterexample with a synthesised generator")
    func exhaustFindsCounterexample() {
        let json = """
        {"name": "Gaute", "age": 30, "active": true}
        """
        let generator = #gen(Person.self, from: json)

        #exhaust(generator, .suppress(.issueReporting)) { person in
            person.age >= 0
        }
    }

    @Test("Generates dictionary properties")
    func dictionaryProperty() {
        let json = """
        {"name": "test", "scores": {"alice": 10, "bob": 20}}
        """
        let generator = #gen(WithDictionary.self, from: json)
        let values = #example(generator, count: 20)

        #expect(Set(values.map(\.name)).count > 1)
        #expect(Set(values.map(\.scores.count)).count > 1)
    }

    @Test("Generates optional properties with both nil and non-nil values")
    func optionalProperty() {
        let json = """
        {"name": "Gaute", "nickname": "Ali"}
        """
        let generator = #gen(WithOptional.self, from: json)
        let values = #example(generator, count: 50)

        let nicknames = values.map(\.nickname)
        #expect(nicknames.contains(where: { $0 == nil }))
        #expect(nicknames.contains(where: { $0 != nil }))
    }

    @Test("Generates optional properties when JSON value is null")
    func optionalPropertyNull() {
        let json = """
        {"name": "Gaute", "nickname": null}
        """
        let generator = #gen(WithOptional.self, from: json)
        let values = #example(generator, count: 50)

        let nicknames = values.map(\.nickname)
        #expect(nicknames.contains(where: { $0 == nil }))
        #expect(nicknames.contains(where: { $0 != nil }))
    }

    @Test("Accepts a Codable instance directly")
    func codableInstance() {
        let example = Person(name: "Gaute", age: 30, active: true)
        let generator = #gen(from: example)
        let values = #example(generator, count: 20)
        print(generator.debugDescription)

        #expect(Set(values.map(\.name)).count > 1)
        #expect(Set(values.map(\.age)).count > 1)
    }

    @Test("Synthesised generators are marked with isSynthesised flag")
    func isSynthesisedFlag() {
        let json = """
        {"name": "Gaute", "age": 30, "active": true}
        """
        let synthesised = #gen(Person.self, from: json)
        let handWritten = #gen(.int(in: 0 ... 100))

        #expect(synthesised.isSynthesized)
        #expect(handWritten.isSynthesized == false)
    }

    @Test("#examine skips reflection for synthesised generators")
    func examineSkipsReflection() {
        let json = """
        {"name": "Gaute", "age": 30, "active": true}
        """
        let generator = #gen(Person.self, from: json)
        let report = #examine(generator, .samples(20))

        #expect(report.passed)
        #expect(report.valuesGenerated == 20)
        #expect(report.reflectionSkipped)
        #expect(report.pinnedFieldCount == 0)
    }

    @Test("#examine reports pinned fields for synthesised generators")
    func examineReportsPinnedFields() {
        let json = """
        {"name": "test", "priority": "high"}
        """
        let generator = #gen(WithNonIterable.self, from: json)
        let report = #examine(generator, .samples(20))
        print()

        #expect(report.passed)
        #expect(report.pinnedFieldCount == 1)
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
