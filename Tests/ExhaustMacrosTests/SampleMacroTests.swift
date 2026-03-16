import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "example": ExampleMacro.self,
]

@Suite("#example macro expansion tests")
struct ExampleMacroTests {
    @Test("Basic single example expands to __example with nil seed")
    func basicSingle() {
        assertMacroExpansion(
            """
            #example(personGen)
            """,
            expandedSource: """
            __ExhaustRuntime.__example(
                personGen,
                seed: nil
            )
            """,
            macros: testMacros
        )
    }

    @Test("Single example with seed passes seed through")
    func singleWithSeed() {
        assertMacroExpansion(
            """
            #example(personGen, seed: 42)
            """,
            expandedSource: """
            __ExhaustRuntime.__example(
                personGen,
                seed: 42
            )
            """,
            macros: testMacros
        )
    }

    @Test("Array example expands to __exampleArray")
    func arrayExample() {
        assertMacroExpansion(
            """
            #example(personGen, count: 10)
            """,
            expandedSource: """
            __ExhaustRuntime.__exampleArray(
                personGen,
                count: 10,
                seed: nil
            )
            """,
            macros: testMacros
        )
    }

    @Test("Array example with seed passes both count and seed")
    func arrayExampleWithSeed() {
        assertMacroExpansion(
            """
            #example(personGen, count: 10, seed: 42)
            """,
            expandedSource: """
            __ExhaustRuntime.__exampleArray(
                personGen,
                count: 10,
                seed: 42
            )
            """,
            macros: testMacros
        )
    }

    @Test("Missing generator produces error diagnostic")
    func missingGenerator() {
        assertMacroExpansion(
            """
            #example()
            """,
            expandedSource: """
            fatalError("#example requires a generator argument")
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.exampleMissingGenerator.rawValue,
                    line: 1,
                    column: 1,
                    severity: .error
                ),
            ],
            macros: testMacros
        )
    }

    @Test("Generator chain is preserved in expansion")
    func generatorChainPreservation() {
        assertMacroExpansion(
            """
            #example(Gen.choose(in: 1...100).array(length: 3...5))
            """,
            expandedSource: """
            __ExhaustRuntime.__example(
                Gen.choose(in: 1...100).array(length: 3...5),
                seed: nil
            )
            """,
            macros: testMacros
        )
    }
}
