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

    // MARK: - Issue.record Rewriting

    @Test("Single Issue.record() routes to void path with detection closure")
    func issueRecordSingleStatement() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                Issue.record()
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "Issue.record()",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
                Issue.record()
            },
                detection: { value in
                try __ExhaustRuntime.__detectRequire(false)
            }
            )
            """,
            macros: testMacros
        )
    }

    @Test("Issue.record alongside #expect rewrites both in detection closure")
    func issueRecordWithExpect() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                if value < 0 {
                    Issue.record("negative")
                }
                #expect(value > 0)
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "if value < 0 {\\n    Issue.record(\\\"negative\\\")\\n}\\n#expect(value > 0)",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
                if value < 0 {
                    Issue.record("negative")
                }
                #expect(value > 0)
            },
                detection: { value in
                if value < 0 {
                    try __ExhaustRuntime.__detectRequire(false)
                }
                try __ExhaustRuntime.__detectRequire(value > 0)
            }
            )
            """,
            macros: testMacros
        )
    }

    // MARK: - Vacuous Void Closure Detection

    @Test("Single-statement switch expression routes to Bool path")
    func switchExpressionBoolPath() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                switch value {
                case 1: true
                case 2: false
                default: false
                }
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaust(
                gen,
                settings: [],
                sourceCode: "switch value {\\ncase 1: true\\ncase 2: false\\ndefault: false\\n}",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                property: { value in
                switch value {
                case 1: true
                case 2: false
                default: false
                }
            }
            )
            """,
            macros: testMacros
        )
    }

    @Test("Single-statement switch with #expect routes to Void path")
    func switchWithExpectVoidPath() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                switch value {
                case 1: #expect(value > 0)
                default: #expect(value != 0)
                }
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "switch value {\\ncase 1: #expect(value > 0)\\ndefault: #expect(value != 0)\\n}",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
                switch value {
                case 1: #expect(value > 0)
                default: #expect(value != 0)
                }
            },
                detection: { value in
                switch value {
                case 1: try __ExhaustRuntime.__detectRequire(value > 0)
                default: try __ExhaustRuntime.__detectRequire(value != 0)
                }
            }
            )
            """,
            macros: testMacros
        )
    }

    @Test("Multi-statement closure with no failure mechanism emits diagnostic")
    func vacuousClosureDiscardedComparison() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                let box = ThreadSafeBox(0)
                box.put(value)
                box.get() == value
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "let box = ThreadSafeBox(0)\\nbox.put(value)\\nbox.get() == value",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
                let box = ThreadSafeBox(0)
                box.put(value)
                box.get() == value
            },
                detection: { value in
                let box = ThreadSafeBox(0)
                box.put(value)
                box.get() == value
            }
            )
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.closureCannotFail.rawValue,
                    line: 1,
                    column: 15,
                    severity: .error
                ),
            ],
            macros: testMacros
        )
    }

    @Test("Multi-statement closure with only void calls emits diagnostic")
    func vacuousClosureVoidCalls() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                doSomething()
                doSomethingElse(value)
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "doSomething()\\ndoSomethingElse(value)",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
                doSomething()
                doSomethingElse(value)
            },
                detection: { value in
                doSomething()
                doSomethingElse(value)
            }
            )
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.closureCannotFail.rawValue,
                    line: 1,
                    column: 15,
                    severity: .error
                ),
            ],
            macros: testMacros
        )
    }

    @Test("Multi-statement closure with try has failure mechanism — no diagnostic")
    func tryIsFailureMechanism() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                let result = try compute(value)
                use(result)
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "let result = try compute(value)\\nuse(result)",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
                let result = try compute(value)
                use(result)
            },
                detection: { value in
                let result = try compute(value)
                use(result)
            }
            )
            """,
            macros: testMacros
        )
    }

    @Test("Multi-statement closure with try? has no failure mechanism — emits diagnostic")
    func tryQuestionIsNotFailureMechanism() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                let result = try? compute(value)
                use(result)
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "let result = try? compute(value)\\nuse(result)",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
                let result = try? compute(value)
                use(result)
            },
                detection: { value in
                let result = try? compute(value)
                use(result)
            }
            )
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.closureCannotFail.rawValue,
                    line: 1,
                    column: 15,
                    severity: .error
                ),
            ],
            macros: testMacros
        )
    }

    @Test("Multi-statement closure with throw has failure mechanism — no diagnostic")
    func throwIsFailureMechanism() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                if value < 0 {
                    throw TestError()
                }
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "if value < 0 {\\n    throw TestError()\\n}",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
                if value < 0 {
                    throw TestError()
                }
            },
                detection: { value in
                if value < 0 {
                    throw TestError()
                }
            }
            )
            """,
            macros: testMacros
        )
    }

    @Test("Multi-statement closure with explicit return does not emit diagnostic")
    func explicitReturnNoDiagnostic() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                let x = compute(value)
                return x == 0
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaust(
                gen,
                settings: [],
                sourceCode: "let x = compute(value)\\nreturn x == 0",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                property: { value in
                let x = compute(value)
                return x == 0
            }
            )
            """,
            macros: testMacros
        )
    }

    @Test("Single-expression closure with comparison does not emit diagnostic")
    func singleExpressionNoDiagnostic() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                value == 0
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaust(
                gen,
                settings: [],
                sourceCode: "value == 0",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                property: { value in
                value == 0
            }
            )
            """,
            macros: testMacros
        )
    }

    @Test("Multi-statement closure with #expect has failure mechanism — no diagnostic")
    func expectIsFailureMechanism() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                let x = compute(value)
                #expect(x == 0)
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "let x = compute(value)\\n#expect(x == 0)",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
                let x = compute(value)
                #expect(x == 0)
            },
                detection: { value in
                let x = compute(value)
                try __ExhaustRuntime.__detectRequire(x == 0)
            }
            )
            """,
            macros: testMacros
        )
    }

    @Test("Multi-statement closure with Issue.record has failure mechanism — no diagnostic")
    func issueRecordIsFailureMechanism() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
                if value < 0 {
                    Issue.record("negative")
                }
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "if value < 0 {\\n    Issue.record(\\\"negative\\\")\\n}",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
                if value < 0 {
                    Issue.record("negative")
                }
            },
                detection: { value in
                if value < 0 {
                    try __ExhaustRuntime.__detectRequire(false)
                }
            }
            )
            """,
            macros: testMacros
        )
    }

    // MARK: - Tab Escaping in sourceCode

    @Test("Tab-indented multi-statement closure escapes tabs in sourceCode")
    func tabIndentedClosureEscapesTabs() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
            \tlet x = compute(value)
            \treturn x == 0
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaust(
                gen,
                settings: [],
                sourceCode: "let x = compute(value)\\n\\treturn x == 0",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                property: { value in
            \tlet x = compute(value)
            \treturn x == 0
            }
            )
            """,
            macros: testMacros
        )
    }

    @Test("Tab-indented void closure with #expect escapes tabs in sourceCode")
    func tabIndentedVoidClosureEscapesTabs() {
        assertMacroExpansion(
            """
            #exhaust(gen) { value in
            \tlet x = compute(value)
            \t#expect(x == 0)
            }
            """,
            expandedSource: """
            __ExhaustRuntime.__exhaustExpect(
                gen,
                settings: [],
                sourceCode: "let x = compute(value)\\n\\t#expect(x == 0)",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                function: #function,
                property: { value in
            \tlet x = compute(value)
            \t#expect(x == 0)
            },
                detection: { value in
            \tlet x = compute(value)
            \ttry __ExhaustRuntime.__detectRequire(x == 0)
            }
            )
            """,
            macros: testMacros
        )
    }

    // MARK: - Error Diagnostics

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

@Suite("escapeForStringLiteral")
struct EscapeForStringLiteralTests {
    @Test("Escapes tab characters")
    func escapesTab() {
        let input = "line1\n\tline2"
        let result = escapeForStringLiteral(input)
        #expect(result == "line1\\n\\tline2")
    }

    @Test("Escapes carriage returns")
    func escapesCarriageReturn() {
        let input = "line1\r\nline2"
        let result = escapeForStringLiteral(input)
        #expect(result == "line1\\r\\nline2")
    }

    @Test("Escapes backslashes before other characters")
    func escapesBackslashFirst() {
        let input = "a\\b\n\tc"
        let result = escapeForStringLiteral(input)
        #expect(result == "a\\\\b\\n\\tc")
    }

    @Test("Escapes double quotes")
    func escapesQuotes() {
        let input = "value == \"hello\""
        let result = escapeForStringLiteral(input)
        #expect(result == "value == \\\"hello\\\"")
    }

    @Test("Result contains no raw control characters")
    func noRawControlCharacters() {
        let input = "let x = value\n\tif x > 0 {\n\t\treturn true\n\t}"
        let result = escapeForStringLiteral(input)
        for scalar in result.unicodeScalars {
            #expect(
                scalar.value >= 0x20 || scalar == " ",
                "Found raw control character U+\(String(scalar.value, radix: 16, uppercase: true))"
            )
        }
    }
}
