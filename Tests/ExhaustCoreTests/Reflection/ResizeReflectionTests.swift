import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Resize reflection")
struct ResizeReflectionTests {
    @Test("A resized size-dependent generator reflects through the active size")
    func sizeDependentGeneratorUsesResize() throws {
        let generator = ReflectiveGenerator<UInt64>.getSize { size in
            Gen.choose(in: 0 ... size).wrapped(isReflective: true)
        }.resize(10).gen

        let tree = try #require(try Interpreters.reflect(generator, with: 10))
        #expect(try Interpreters.replay(generator, using: tree) == 10)
        expectOutOfRangeReflection {
            _ = try Interpreters.reflect(generator, with: 11)
        }
    }

    @Test("A resized scaled choice rejects values outside its effective range")
    func scaledChoiceUsesResize() throws {
        let generator = Gen.resize(
            10,
            Gen.choose(in: UInt64(0) ... 100, scaling: .linear)
        )

        let tree = try #require(try Interpreters.reflect(generator, with: 10))
        #expect(try Interpreters.replay(generator, using: tree) == 10)
        expectOutOfRangeReflection {
            _ = try Interpreters.reflect(generator, with: 11)
        }
    }

    @Test("An inner resize overrides and then restores the outer reflection size")
    func nestedResizeScopes() throws {
        let generator = Gen.resize(
            20,
            Gen.zip(
                Gen.resize(10, Gen.rawGetSize()),
                Gen.rawGetSize()
            )
        )
        let target: (UInt64, UInt64) = (10, 20)

        let tree = try #require(try Interpreters.reflect(generator, with: target))
        let replayed = try #require(try Interpreters.replay(generator, using: tree))

        #expect(replayed.0 == target.0)
        #expect(replayed.1 == target.1)
    }
}

private func expectOutOfRangeReflection(_ operation: () throws -> Void) {
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
