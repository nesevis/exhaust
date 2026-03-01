import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "exhaust": ExhaustTestMacro.self,
]

@Suite("#exhaust macro expansion tests")
struct ExhaustMacroTests {
    @Test("Basic exhaust with trailing closure captures source")
    func basicExhaust() {
        assertMacroExpansion(
            """
            #exhaust(personGen) { person in
                person.age >= 0
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaust(
                personGen,
                settings: [],
                sourceCode: "person.age >= 0",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                property: { person in
                person.age >= 0
            }
            )
            """,
            macros: testMacros,
        )
    }

    @Test("Exhaust with settings and trailing closure")
    func exhaustWithSettings() {
        assertMacroExpansion(
            """
            #exhaust(personGen, .maxIterations(1000), .replay(42)) { person in
                person.age >= 0
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaust(
                personGen,
                settings: [.maxIterations(1000), .replay(42)],
                sourceCode: "person.age >= 0",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                property: { person in
                person.age >= 0
            }
            )
            """,
            macros: testMacros,
        )
    }

    @Test("Function reference passes nil sourceCode")
    func functionReference() {
        assertMacroExpansion(
            """
            #exhaust(personGen, property: isValid)
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaust(
                personGen,
                settings: [],
                sourceCode: nil,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                property: isValid
            )
            """,
            macros: testMacros,
        )
    }

    @Test("Function reference with settings passes nil sourceCode")
    func functionReferenceWithSettings() {
        assertMacroExpansion(
            """
            #exhaust(personGen, .maxIterations(500), property: isValid)
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaust(
                personGen,
                settings: [.maxIterations(500)],
                sourceCode: nil,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                property: isValid
            )
            """,
            macros: testMacros,
        )
    }

    @Test("Missing property produces error")
    func missingProperty() {
        assertMacroExpansion(
            """
            #exhaust(personGen)
            """,
            expandedSource: """
            fatalError("#exhaust requires a property argument")
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.exhaustMissingProperty.rawValue,
                    line: 1,
                    column: 1,
                    severity: .error,
                ),
            ],
            macros: testMacros,
        )
    }
}
