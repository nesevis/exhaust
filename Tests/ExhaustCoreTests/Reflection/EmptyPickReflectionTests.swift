import ExhaustCore
import Testing

@Suite("Empty pick reflection rejection")
struct EmptyPickReflectionTests {
    @Test("A pick with no matching numeric branch cannot reflect an empty history", arguments: [-1, 4, 9, 14])
    func rejectsOutOfRange(value: Int) {
        let generator = Gen.pick(choices: [
            (1, Gen.choose(in: 0 ... 3)),
            (1, Gen.choose(in: 10 ... 13)),
        ])
        expectPickReflectionOutOfRange {
            _ = try Interpreters.reflect(generator, with: value)
        }
    }

    @Test("A single-arm pick rejects values outside its payload range")
    func rejectsSingleArm() throws {
        let generator = Gen.pick(choices: [(1, Gen.choose(in: 0 ... 3))])
        expectPickReflectionOutOfRange {
            _ = try Interpreters.reflect(generator, with: 4)
        }
        for value in 0 ... 3 {
            let tree = try #require(try Interpreters.reflect(generator, with: value))
            #expect(try Interpreters.replay(generator, using: tree) == value)
        }
    }
}

private func expectPickReflectionOutOfRange(_ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected reflection to reject the value as out of range")
    } catch let error as ReflectionError {
        guard case .inputWasOutOfGeneratorRange = error else {
            Issue.record("Expected inputWasOutOfGeneratorRange, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected inputWasOutOfGeneratorRange, got \(error)")
    }
}
