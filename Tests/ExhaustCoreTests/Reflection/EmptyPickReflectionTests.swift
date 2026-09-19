import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Empty pick reflection rejection")
struct EmptyPickReflectionTests {
    @Test("A pick with no matching numeric branch cannot reflect an empty history", arguments: [-1, 4, 9, 14])
    func rejectsOutOfRange(value: Int) {
        let generator = Gen.pick(choices: [
            (1, Gen.choose(in: 0 ... 3)),
            (1, Gen.choose(in: 10 ... 13)),
        ])
        expectReflectionOutOfRange {
            _ = try Interpreters.reflect(generator, with: value)
        }
    }

    @Test("A single-arm pick rejects values outside its payload range")
    func rejectsSingleArm() throws {
        let generator = Gen.pick(choices: [(1, Gen.choose(in: 0 ... 3))])
        expectReflectionOutOfRange {
            _ = try Interpreters.reflect(generator, with: 4)
        }
        for value in 0 ... 3 {
            let tree = try #require(try Interpreters.reflect(generator, with: value))
            #expect(try Interpreters.replay(generator, using: tree) == value)
        }
    }
}
