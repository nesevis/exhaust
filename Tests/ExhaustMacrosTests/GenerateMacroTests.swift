import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "generate": GenerateMacro.self,
]

@Suite("GenerateMacro expansion tests")
struct GenerateMacroTests {
    @Test("Single generator with struct init produces Mirror-based bidirectional")
    func singleGeneratorBidirectional() {
        assertMacroExpansion(
            """
            #gen(nameGen) { name in
                Person(name: name)
            }
            """,
            expandedSource: """
            Gen.contramap({ _mirrorExtract($0, label: "name") }, nameGen.map { name in
                Person(name: name)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Two generators with struct init produces _mirrorMappedZip")
    func twoGeneratorsBidirectional() {
        assertMacroExpansion(
            """
            #gen(nameGen, ageGen) { name, age in
                Person(name: name, age: age)
            }
            """,
            expandedSource: """
            Gen._mirrorMappedZip(nameGen, ageGen, labels: ["name", "age"], forward: { name, age in
                Person(name: name, age: age)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Reordered arguments produce correctly ordered backward labels")
    func reorderedArguments() {
        assertMacroExpansion(
            """
            #gen(ageGen, nameGen) { age, name in
                Person(name: name, age: age)
            }
            """,
            expandedSource: """
            Gen._mirrorMappedZip(ageGen, nameGen, labels: ["age", "name"], forward: { age, name in
                Person(name: name, age: age)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Shorthand parameters with non-init body produce forward-only")
    func shorthandParametersFallback() {
        assertMacroExpansion(
            """
            #gen(intGen) { $0 * 2 }
            """,
            expandedSource: """
            intGen.map { $0 * 2 }
            """,
            macros: testMacros
        )
    }

    @Test("Single generator with shorthand parameter produces bidirectional")
    func singleGeneratorShorthandBidirectional() {
        assertMacroExpansion(
            """
            #gen(nameGen) { Person(name: $0) }
            """,
            expandedSource: """
            Gen.contramap({ _mirrorExtract($0, label: "name") }, nameGen.map { Person(name: $0) })
            """,
            macros: testMacros
        )
    }

    @Test("Two generators with shorthand parameters produce bidirectional")
    func twoGeneratorsShorthandBidirectional() {
        assertMacroExpansion(
            """
            #gen(nameGen, ageGen) { Person(name: $0, age: $1) }
            """,
            expandedSource: """
            Gen._mirrorMappedZip(nameGen, ageGen, labels: ["name", "age"], forward: { Person(name: $0, age: $1) })
            """,
            macros: testMacros
        )
    }

    @Test("Shorthand parameters with reordered indices produce correct backward labels")
    func shorthandReorderedIndices() {
        assertMacroExpansion(
            """
            #gen(ageGen, nameGen) { Person(name: $1, age: $0) }
            """,
            expandedSource: """
            Gen._mirrorMappedZip(ageGen, nameGen, labels: ["age", "name"], forward: { Person(name: $1, age: $0) })
            """,
            macros: testMacros
        )
    }

    @Test("Complex argument expressions produce forward-only")
    func complexExpressionFallback() {
        assertMacroExpansion(
            """
            #gen(nameGen) { name in
                Person(name: name.uppercased())
            }
            """,
            expandedSource: """
            nameGen.map { name in
                Person(name: name.uppercased())
            }
            """,
            macros: testMacros
        )
    }

    @Test("Multi-statement closure produces forward-only")
    func multiStatementFallback() {
        assertMacroExpansion(
            """
            #gen(intGen) { x in
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
            macros: testMacros
        )
    }

    @Test("Single generator without closure passes through")
    func singleGeneratorPassthrough() {
        assertMacroExpansion(
            """
            #gen(intGen)
            """,
            expandedSource: """
            intGen
            """,
            macros: testMacros
        )
    }

    @Test("Multiple generators without closure produce zip")
    func multipleGeneratorsZip() {
        assertMacroExpansion(
            """
            #gen(intGen, stringGen)
            """,
            expandedSource: """
            Gen.zip(intGen, stringGen)
            """,
            macros: testMacros
        )
    }

    @Test("Three generators with struct init")
    func threeGeneratorsBidirectional() {
        assertMacroExpansion(
            """
            #gen(nameGen, ageGen, emailGen) { name, age, email in
                User(name: name, age: age, email: email)
            }
            """,
            expandedSource: """
            Gen._mirrorMappedZip(nameGen, ageGen, emailGen, labels: ["name", "age", "email"], forward: { name, age, email in
                User(name: name, age: age, email: email)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Single generator with return statement produces Mirror-based bidirectional")
    func singleGeneratorWithReturn() {
        assertMacroExpansion(
            """
            #gen(nameGen) { name in
                return Person(name: name)
            }
            """,
            expandedSource: """
            Gen.contramap({ _mirrorExtract($0, label: "name") }, nameGen.map { name in
                return Person(name: name)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Unlabeled arguments produce forward-only")
    func unlabeledArgumentsFallback() {
        assertMacroExpansion(
            """
            #gen(intGen) { x in
                Wrapper(x)
            }
            """,
            expandedSource: """
            intGen.map { x in
                Wrapper(x)
            }
            """,
            macros: testMacros
        )
    }
}
