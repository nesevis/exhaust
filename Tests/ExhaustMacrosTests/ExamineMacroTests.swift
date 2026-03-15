import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "examine": ExamineMacro.self,
]

@Suite("#examine macro expansion tests")
struct ExamineMacroTests {
    @Test("Basic examine expands with default samples and nil seed")
    func basicExamine() {
        assertMacroExpansion(
            """
            #examine(intGen)
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                intGen,
                samples: 200,
                seed: nil,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("Examine with custom samples count")
    func customSamples() {
        assertMacroExpansion(
            """
            #examine(intGen, samples: 500)
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                intGen,
                samples: 500,
                seed: nil,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("Examine with seed passes seed through")
    func withSeed() {
        assertMacroExpansion(
            """
            #examine(intGen, seed: 42)
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                intGen,
                samples: 200,
                seed: 42,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("Examine with both samples and seed")
    func samplesAndSeed() {
        assertMacroExpansion(
            """
            #examine(intGen, samples: 100, seed: 99)
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                intGen,
                samples: 100,
                seed: 99,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("Missing generator produces error diagnostic")
    func missingGenerator() {
        assertMacroExpansion(
            """
            #examine()
            """,
            expandedSource: """
            fatalError("#examine requires a generator argument")
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.examineMissingGenerator.rawValue,
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
            #examine(.int(in: 1...100).array(length: 3...5))
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                .int(in: 1...100).array(length: 3...5),
                samples: 200,
                seed: nil,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }
}
