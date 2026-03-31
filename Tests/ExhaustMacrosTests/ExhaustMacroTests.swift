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
            macros: testMacros
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
            macros: testMacros
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
            macros: testMacros
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
            macros: testMacros
        )
    }

    // MARK: - Async Expansion Tests

    @Test("Async Bool trailing closure expands to __exhaustAsync")
    func asyncBoolTrailingClosure() {
        let asyncMacros: [String: any Macro.Type] = [
            "exhaust": ExhaustAsyncTestMacro.self,
        ]
        assertMacroExpansion(
            """
            #exhaust(personGen) { person in
                await actor.validate(person)
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustAsync(
                personGen,
                settings: [],
                sourceCode: "await actor.validate(person)",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { person in
                await actor.validate(person)
            }
            )
            """,
            macros: asyncMacros
        )
    }

    @Test("Async Void trailing closure with #expect expands to __exhaustExpectAsync")
    func asyncVoidTrailingClosure() {
        let asyncMacros: [String: any Macro.Type] = [
            "exhaust": ExhaustAsyncTestMacro.self,
        ]
        assertMacroExpansion(
            """
            #exhaust(personGen) { person in
                let result = await actor.validate(person)
                #expect(result)
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpectAsync(
                personGen,
                settings: [],
                sourceCode: "let result = await actor.validate(person)\\n#expect(result)",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { person in
                let result = await actor.validate(person)
                #expect(result)
            },
                detection: { person in
                let result = await actor.validate(person)
                try __ExhaustRuntime.__detectRequire(result)
            }
            )
            """,
            macros: asyncMacros
        )
    }

    @Test("Async function reference expands to __exhaustAsync")
    func asyncFunctionReference() {
        let asyncMacros: [String: any Macro.Type] = [
            "exhaust": ExhaustAsyncTestMacro.self,
        ]
        assertMacroExpansion(
            """
            #exhaust(personGen, property: asyncIsValid)
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustAsync(
                personGen,
                settings: [],
                sourceCode: nil,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: asyncIsValid
            )
            """,
            macros: asyncMacros
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
                    severity: .error
                ),
            ],
            macros: testMacros
        )
    }
}
