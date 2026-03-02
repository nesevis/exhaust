import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "sample": SampleMacro.self,
]

@Suite("#sample macro expansion tests")
struct SampleMacroTests {
    @Test("Basic single sample expands to __sample with nil seed")
    func basicSingle() {
        assertMacroExpansion(
            """
            #sample(personGen)
            """,
            expandedSource: """
            __ExhaustRuntime.__sample(
                personGen,
                seed: nil
            )
            """,
            macros: testMacros,
        )
    }

    @Test("Single sample with seed passes seed through")
    func singleWithSeed() {
        assertMacroExpansion(
            """
            #sample(personGen, seed: 42)
            """,
            expandedSource: """
            __ExhaustRuntime.__sample(
                personGen,
                seed: 42
            )
            """,
            macros: testMacros,
        )
    }

    @Test("Array sample expands to __sampleArray")
    func arraySample() {
        assertMacroExpansion(
            """
            #sample(personGen, count: 10)
            """,
            expandedSource: """
            __ExhaustRuntime.__sampleArray(
                personGen,
                count: 10,
                seed: nil
            )
            """,
            macros: testMacros,
        )
    }

    @Test("Array sample with seed passes both count and seed")
    func arraySampleWithSeed() {
        assertMacroExpansion(
            """
            #sample(personGen, count: 10, seed: 42)
            """,
            expandedSource: """
            __ExhaustRuntime.__sampleArray(
                personGen,
                count: 10,
                seed: 42
            )
            """,
            macros: testMacros,
        )
    }

    @Test("Missing generator produces error diagnostic")
    func missingGenerator() {
        assertMacroExpansion(
            """
            #sample()
            """,
            expandedSource: """
            fatalError("#sample requires a generator argument")
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.sampleMissingGenerator.rawValue,
                    line: 1,
                    column: 1,
                    severity: .error,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test("Generator chain is preserved in expansion")
    func generatorChainPreservation() {
        assertMacroExpansion(
            """
            #sample(Gen.choose(in: 1...100).array(length: 3...5))
            """,
            expandedSource: """
            __ExhaustRuntime.__sample(
                Gen.choose(in: 1...100).array(length: 3...5),
                seed: nil
            )
            """,
            macros: testMacros,
        )
    }
}
