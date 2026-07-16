import Testing
@testable import ExhaustCore

@Suite("Forward-only reflection")
struct ForwardOnlyReflectionTests {
    @Test("Forward-only map reports its exact reflection error")
    func mapReportsExactError() {
        let generator = ReflectiveGenerator(Gen.just(1)).map(String.init)

        #expect(throws: ReflectionError.forwardOnlyMap(
            inputType: "Int",
            outputType: "String"
        )) {
            _ = try Interpreters.reflect(generator.gen, with: "1")
        }
    }

    @Test("Forward-only bind reports its exact reflection error")
    func bindReportsExactError() {
        let generator = ReflectiveGenerator(Gen.just(1)).bind { value in
            ReflectiveGenerator(Gen.just(String(value)))
        }

        #expect(throws: ReflectionError.forwardOnlyBind(
            inputType: "Int",
            outputType: "String"
        )) {
            _ = try Interpreters.reflect(generator.gen, with: "1")
        }
    }
}
