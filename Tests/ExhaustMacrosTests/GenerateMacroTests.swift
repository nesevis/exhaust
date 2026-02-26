import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "gen": GenerateMacro.self,
]

@Suite("GenerateMacro expansion tests")
struct GenerateMacroTests {
    @Test("Single generator with struct init produces _macroMap bidirectional")
    func singleGeneratorBidirectional() {
        assertMacroExpansion(
            """
            #gen(nameGen) { name in
                Person(name: name)
            }
            """,
            expandedSource: """
            Gen._macroMap(nameGen, label: "name", forward: { name in
                Person(name: name)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Two generators with struct init produces _macroZip")
    func twoGeneratorsBidirectional() {
        assertMacroExpansion(
            """
            #gen(nameGen, ageGen) { name, age in
                Person(name: name, age: age)
            }
            """,
            expandedSource: """
            Gen._macroZip(nameGen, ageGen, labels: ["name", "age"], forward: { name, age in
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
            Gen._macroZip(ageGen, nameGen, labels: ["age", "name"], forward: { age, name in
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
            Gen._macroMap(nameGen, label: "name", forward: { Person(name: $0) })
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
            Gen._macroZip(nameGen, ageGen, labels: ["name", "age"], forward: { Person(name: $0, age: $1) })
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
            Gen._macroZip(ageGen, nameGen, labels: ["age", "name"], forward: { Person(name: $1, age: $0) })
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

    @Test("Implicit member chain gets ReflectiveGenerator prefix in expansion")
    func implicitMemberChainResolution() {
        // The macro correctly prepends ReflectiveGenerator to resolve implicit member chains.
        // However, the compiler type-checks macro arguments BEFORE expansion, so
        // #gen(.int16().array(length: 0...10)) still fails at the call site.
        // Use ReflectiveGenerator.int16().array(length: 0...10) directly instead.
        assertMacroExpansion(
            """
            #gen(.int16().array(length: 0...10))
            """,
            expandedSource: """
            ReflectiveGenerator.int16().array(length: 0...10)
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
            Gen._macroZip(nameGen, ageGen, emailGen, labels: ["name", "age", "email"], forward: { name, age, email in
                User(name: name, age: age, email: email)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Single generator with return statement produces _macroMap bidirectional")
    func singleGeneratorWithReturn() {
        assertMacroExpansion(
            """
            #gen(nameGen) { name in
                return Person(name: name)
            }
            """,
            expandedSource: """
            Gen._macroMap(nameGen, label: "name", forward: { name in
                return Person(name: name)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Unlabeled arguments produce bidirectional with positional Mirror labels")
    func unlabeledArgumentsBidirectional() {
        assertMacroExpansion(
            """
            #gen(intGen) { x in
                Wrapper(x)
            }
            """,
            expandedSource: """
            Gen._macroMap(intGen, label: ".0", forward: { x in
                Wrapper(x)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Two unlabeled arguments produce bidirectional with positional Mirror labels")
    func twoUnlabeledArgumentsBidirectional() {
        assertMacroExpansion(
            """
            #gen(intGen, strGen) { x, y in
                Pair(x, y)
            }
            """,
            expandedSource: """
            Gen._macroZip(intGen, strGen, labels: [".0", ".1"], forward: { x, y in
                Pair(x, y)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Shorthand parameters with unlabeled arguments produce bidirectional")
    func shorthandUnlabeledBidirectional() {
        assertMacroExpansion(
            """
            #gen(intGen) { Wrapper($0) }
            """,
            expandedSource: """
            Gen._macroMap(intGen, label: ".0", forward: { Wrapper($0) })
            """,
            macros: testMacros
        )
    }

    // MARK: - Enum case pattern-matching backward

    @Test("Single-value enum case produces pattern-matching backward")
    func singleEnumCaseBidirectional() {
        assertMacroExpansion(
            """
            #gen(intGen) { age in
                Pet.cat(age)
            }
            """,
            expandedSource: """
            Gen._macroMap(intGen, backward: { guard case let .cat(v0) = $0 else { return nil }; return v0 }, forward: { age in
                Pet.cat(age)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Multi-value enum case produces pattern-matching backward")
    func multiEnumCaseBidirectional() {
        assertMacroExpansion(
            """
            #gen(intGen, strGen) { age, name in
                Pet.dog(age, name)
            }
            """,
            expandedSource: """
            Gen._macroZip(intGen, strGen, backward: { guard case let .dog(v0, v1) = $0 else { return nil }; return [v0 as Any, v1 as Any] }, forward: { age, name in
                Pet.dog(age, name)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Labeled enum case produces labeled pattern bindings")
    func labeledEnumCaseBidirectional() {
        assertMacroExpansion(
            """
            #gen(intGen) { age in
                Pet.cat(age: age)
            }
            """,
            expandedSource: """
            Gen._macroMap(intGen, backward: { guard case let .cat(age: v0) = $0 else { return nil }; return v0 }, forward: { age in
                Pet.cat(age: age)
            })
            """,
            macros: testMacros
        )
    }

    @Test("Shorthand enum case produces pattern-matching backward")
    func shorthandEnumCaseBidirectional() {
        assertMacroExpansion(
            """
            #gen(intGen) { Pet.cat($0) }
            """,
            expandedSource: """
            Gen._macroMap(intGen, backward: { guard case let .cat(v0) = $0 else { return nil }; return v0 }, forward: { Pet.cat($0) })
            """,
            macros: testMacros
        )
    }

    @Test("Reordered enum case parameters produce correctly ordered backward")
    func reorderedEnumCaseBidirectional() {
        assertMacroExpansion(
            """
            #gen(nameGen, ageGen) { name, age in
                Pet.dog(age, name)
            }
            """,
            expandedSource: """
            Gen._macroZip(nameGen, ageGen, backward: { guard case let .dog(v0, v1) = $0 else { return nil }; return [v1 as Any, v0 as Any] }, forward: { name, age in
                Pet.dog(age, name)
            })
            """,
            macros: testMacros
        )
    }
}
