import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "generate": GenerateMacro.self,
]

@Suite("GenerateMacro expansion tests")
struct GenerateMacroTests {
    @Test("Single generator with struct init produces bidirectional mapped")
    func singleGeneratorBidirectional() {
        assertMacroExpansion(
            """
            #generate(nameGen) { name in
                Person(name: name)
            }
            """,
            expandedSource: """
            nameGen.mapped(forward: { name in
                Person(name: name)
            }, backward: { $0.name })
            """,
            macros: testMacros
        )
    }

    @Test("Two generators with struct init produces zip + bidirectional mapped")
    func twoGeneratorsBidirectional() {
        assertMacroExpansion(
            """
            #generate(nameGen, ageGen) { name, age in
                Person(name: name, age: age)
            }
            """,
            expandedSource: """
            Gen.zip(nameGen, ageGen).mapped(forward: { name, age in
                Person(name: name, age: age)
            }, backward: { ($0.name, $0.age) })
            """,
            macros: testMacros
        )
    }

    @Test("Reordered arguments produce correctly ordered backward tuple")
    func reorderedArguments() {
        assertMacroExpansion(
            """
            #generate(ageGen, nameGen) { age, name in
                Person(name: name, age: age)
            }
            """,
            expandedSource: """
            Gen.zip(ageGen, nameGen).mapped(forward: { age, name in
                Person(name: name, age: age)
            }, backward: { ($0.age, $0.name) })
            """,
            macros: testMacros
        )
    }

    @Test("Shorthand parameters produce forward-only with warning")
    func shorthandParametersFallback() {
        assertMacroExpansion(
            """
            #generate(intGen) { $0 * 2 }
            """,
            expandedSource: """
            intGen.map { $0 * 2 }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.forwardOnlyShorthandParams.rawValue,
                    line: 1,
                    column: 20,
                    severity: .warning
                ),
            ],
            macros: testMacros
        )
    }

    @Test("Complex argument expressions produce forward-only with warning")
    func complexExpressionFallback() {
        assertMacroExpansion(
            """
            #generate(nameGen) { name in
                Person(name: name.uppercased())
            }
            """,
            expandedSource: """
            nameGen.map { name in
                Person(name: name.uppercased())
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.forwardOnlyComplexArguments.rawValue,
                    line: 1,
                    column: 20,
                    severity: .warning
                ),
            ],
            macros: testMacros
        )
    }

    @Test("Multi-statement closure produces forward-only with warning")
    func multiStatementFallback() {
        assertMacroExpansion(
            """
            #generate(intGen) { x in
                let doubled = x * 2
                return doubled
            }
            """,
            expandedSource: """
            intGen.map { x in
                let doubled = x * 2
                return doubled
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.forwardOnlyMultiStatement.rawValue,
                    line: 1,
                    column: 19,
                    severity: .warning
                ),
            ],
            macros: testMacros
        )
    }

    @Test("Missing trailing closure produces error")
    func missingTrailingClosure() {
        assertMacroExpansion(
            """
            #generate(intGen)
            """,
            expandedSource: """
            fatalError("#generate requires a trailing closure")
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.missingTrailingClosure.rawValue,
                    line: 1,
                    column: 1,
                    severity: .error
                ),
            ],
            macros: testMacros
        )
    }

    @Test("Three generators with struct init")
    func threeGeneratorsBidirectional() {
        assertMacroExpansion(
            """
            #generate(nameGen, ageGen, emailGen) { name, age, email in
                User(name: name, age: age, email: email)
            }
            """,
            expandedSource: """
            Gen.zip(nameGen, ageGen, emailGen).mapped(forward: { name, age, email in
                User(name: name, age: age, email: email)
            }, backward: { ($0.name, $0.age, $0.email) })
            """,
            macros: testMacros
        )
    }

    @Test("Single generator with return statement produces bidirectional mapped")
    func singleGeneratorWithReturn() {
        assertMacroExpansion(
            """
            #generate(nameGen) { name in
                return Person(name: name)
            }
            """,
            expandedSource: """
            nameGen.mapped(forward: { name in
                return Person(name: name)
            }, backward: { $0.name })
            """,
            macros: testMacros
        )
    }

    @Test("Unlabeled arguments produce forward-only with warning")
    func unlabeledArgumentsFallback() {
        assertMacroExpansion(
            """
            #generate(intGen) { x in
                Wrapper(x)
            }
            """,
            expandedSource: """
            intGen.map { x in
                Wrapper(x)
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: ExhaustMacroDiagnostic.forwardOnlyUnlabeledArguments.rawValue,
                    line: 1,
                    column: 19,
                    severity: .warning
                ),
            ],
            macros: testMacros
        )
    }
}
