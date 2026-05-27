#if os(macOS)
    import MacroTesting
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "#example macro expansion tests",
        .macros(["example": ExampleMacro.self], record: .failed)
    )
    struct ExampleMacroTests {
        @Test("Basic single example expands to __example with nil seed")
        func basicSingle() {
            assertMacro {
                """
                #example(personGen)
                """
            } expansion: {
                """
                __ExhaustRuntime.__example(
                    personGen,
                    seed: nil,
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Single example with seed passes seed through")
        func singleWithSeed() {
            assertMacro {
                """
                #example(personGen, seed: 42)
                """
            } expansion: {
                """
                __ExhaustRuntime.__example(
                    personGen,
                    seed: 42,
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Array example expands to __exampleArray")
        func arrayExample() {
            assertMacro {
                """
                #example(personGen, count: 10)
                """
            } expansion: {
                """
                __ExhaustRuntime.__exampleArray(
                    personGen,
                    count: 10,
                    seed: nil,
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Array example with seed passes both count and seed")
        func arrayExampleWithSeed() {
            assertMacro {
                """
                #example(personGen, count: 10, seed: 42)
                """
            } expansion: {
                """
                __ExhaustRuntime.__exampleArray(
                    personGen,
                    count: 10,
                    seed: 42,
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Missing generator produces error diagnostic")
        func missingGenerator() {
            assertMacro {
                """
                #example()
                """
            } diagnostics: {
                """
                #example()
                ┬─────────
                ╰─ 🛑 #example requires a generator as its first argument
                """
            }
        }

        @Test("Generator chain is preserved in expansion")
        func generatorChainPreservation() {
            assertMacro {
                """
                #example(Gen.choose(in: 1...100).array(length: 3...5))
                """
            } expansion: {
                """
                __ExhaustRuntime.__example(
                    Gen.choose(in: 1 ... 100).array(length: 3 ... 5),
                    seed: nil,
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }
    }
#endif
