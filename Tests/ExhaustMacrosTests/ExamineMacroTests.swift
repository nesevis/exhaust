import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "examine": ExamineMacro.self,
]

@Suite("#examine macro expansion tests")
struct ExamineMacroTests {
    @Test("Basic examine expands with empty settings")
    func basicExamine() {
        assertMacroExpansion(
            """
            #examine(intGen)
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                intGen,
                settings: [],
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
            #examine(intGen, .samples(500))
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                intGen,
                settings: [.samples(500)],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("Examine with replay seed")
    func withReplaySeed() {
        assertMacroExpansion(
            """
            #examine(intGen, .replay(42))
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                intGen,
                settings: [.replay(42)],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("Examine with samples and replay seed")
    func samplesAndReplaySeed() {
        assertMacroExpansion(
            """
            #examine(intGen, .samples(100), .replay(99))
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                intGen,
                settings: [.samples(100), .replay(99)],
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
                settings: [],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("Severity settings are preserved in expansion")
    func severitySettings() {
        assertMacroExpansion(
            """
            #examine(gen, .reflection(.warning), .determinism(.error))
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                gen,
                settings: [.reflection(.warning), .determinism(.error)],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("Global severity with per-check override")
    func globalSeverityWithOverride() {
        assertMacroExpansion(
            """
            #examine(gen, .severity(.silent), .reflection(.warning))
            """,
            expandedSource: """
            __ExhaustRuntime.__examine(
                gen,
                settings: [.severity(.silent), .reflection(.warning)],
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
