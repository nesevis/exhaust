#if os(macOS)
    import MacroTesting
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "GenerateFromDecodableMacro expansion tests",
        .macros(
            [
                "gen": GenerateFromDecodableMacro.self,
            ],
            record: .failed
        )
    )
    struct GenerateFromDecodableMacroTests {
        @Test("Type and String expands to _macroGenDecodable with .get()")
        func typeAndString() {
            assertMacro {
                """
                #gen(Person.self, from: json)
                """
            } expansion: {
                """
                __ExhaustRuntime._macroGenDecodable(Person.self, from: json).get()
                """
            }
        }

        @Test("Type and Data expands to _macroGenDecodable with .get()")
        func typeAndData() {
            assertMacro {
                """
                #gen(Person.self, from: data)
                """
            } expansion: {
                """
                __ExhaustRuntime._macroGenDecodable(Person.self, from: data).get()
                """
            }
        }

        @Test("Type and inline JSON string")
        func inlineJSON() {
            assertMacro {
                #"""
                #gen(Person.self, from: "{\"name\": \"Chris\"}")
                """#
            } expansion: {
                #"""
                __ExhaustRuntime._macroGenDecodable(Person.self, from: "{\"name\": \"Chris\"}").get()
                """#
            }
        }
    }

    @Suite(
        "GenerateFromCodableInstanceMacro expansion tests",
        .macros(
            [
                "gen": GenerateFromCodableInstanceMacro.self,
            ],
            record: .failed
        )
    )
    struct GenerateFromCodableInstanceMacroTests {
        @Test("Instance expands to _macroGenCodableInstance with .get()")
        func instance() {
            assertMacro {
                """
                #gen(from: person)
                """
            } expansion: {
                """
                __ExhaustRuntime._macroGenCodableInstance(person).get()
                """
            }
        }

        @Test("Inline instance construction")
        func inlineInstance() {
            assertMacro {
                """
                #gen(from: Person(name: "Chris", age: 42))
                """
            } expansion: {
                """
                __ExhaustRuntime._macroGenCodableInstance(Person(name: "Chris", age: 42)).get()
                """
            }
        }
    }
#endif
