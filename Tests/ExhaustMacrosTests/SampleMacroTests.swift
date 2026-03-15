import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "extract": ExtractMacro.self,
]

@Suite("#extract macro expansion tests")
struct ExtractMacroTests {
    @Test("Basic single extract expands to __extract with nil seed")
    func basicSingle() {
        assertMacroExpansion(
            """
            #extract(personGen)
            """,
            expandedSource: """
            __ExhaustRuntime.__extract(
                personGen,
                seed: nil
            )
            """,
            macros: testMacros
        )
    }

    @Test("Single extract with seed passes seed through")
    func singleWithSeed() {
        assertMacroExpansion(
            """
            #extract(personGen, seed: 42)
            """,
            expandedSource: """
            __ExhaustRuntime.__extract(
                personGen,
                seed: 42
            )
            """,
            macros: testMacros
        )
    }

    @Test("Array extract expands to __extractArray")
    func arrayExtract() {
        assertMacroExpansion(
            """
            #extract(personGen, count: 10)
            """,
            expandedSource: """
            __ExhaustRuntime.__extractArray(
                personGen,
                count: 10,
                seed: nil
            )
            """,
            macros: testMacros
        )
    }

    @Test("Array extract with seed passes both count and seed")
    func arrayExtractWithSeed() {
        assertMacroExpansion(
            """
            #extract(personGen, count: 10, seed: 42)
            """,
            expandedSource: """
            __ExhaustRuntime.__extractArray(
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
            #extract()
            """,
            expandedSource: """
            fatalError("#extract requires a generator argument")
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.extractMissingGenerator.rawValue,
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
            #extract(Gen.choose(in: 1...100).array(length: 3...5))
            """,
            expandedSource: """
            __ExhaustRuntime.__extract(
                Gen.choose(in: 1...100).array(length: 3...5),
                seed: nil
            )
            """,
            macros: testMacros
        )
    }
}
