#if os(macOS)
    import MacroTesting
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "#examine macro expansion tests",
        .macros(["examine": ExamineMacro.self], record: .failed)
    )
    struct ExamineMacroTests {
        @Test("Basic examine expands with empty settings")
        func basicExamine() {
            assertMacro {
                """
                #examine(intGen)
                """
            } expansion: {
                """
                __ExhaustRuntime.__examine(
                    intGen,
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Examine with custom samples count")
        func customSamples() {
            assertMacro {
                """
                #examine(intGen, .samples(500))
                """
            } expansion: {
                """
                __ExhaustRuntime.__examine(
                    intGen,
                    settings: [.samples(500)],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Examine with replay seed")
        func withReplaySeed() {
            assertMacro {
                """
                #examine(intGen, .replay(42))
                """
            } expansion: {
                """
                __ExhaustRuntime.__examine(
                    intGen,
                    settings: [.replay(42)],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Examine with samples and replay seed")
        func samplesAndReplaySeed() {
            assertMacro {
                """
                #examine(intGen, .samples(100), .replay(99))
                """
            } expansion: {
                """
                __ExhaustRuntime.__examine(
                    intGen,
                    settings: [.samples(100), .replay(99)],
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
                #examine()
                """
            } diagnostics: {
                """
                #examine()
                ┬─────────
                ╰─ 🛑 #examine requires a generator as its first argument
                """
            }
        }

        @Test("Generator chain is preserved in expansion")
        func generatorChainPreservation() {
            assertMacro {
                """
                #examine(.int(in: 1...100).array(length: 3...5))
                """
            } expansion: {
                """
                __ExhaustRuntime.__examine(
                    .int(in: 1 ... 100).array(length: 3 ... 5),
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Severity settings are preserved in expansion")
        func severitySettings() {
            assertMacro {
                """
                #examine(gen, .reflection(.warning), .determinism(.error))
                """
            } expansion: {
                """
                __ExhaustRuntime.__examine(
                    gen,
                    settings: [.reflection(.warning), .determinism(.error)],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Global severity with per-check override")
        func globalSeverityWithOverride() {
            assertMacro {
                """
                #examine(gen, .severity(.silent), .reflection(.warning))
                """
            } expansion: {
                """
                __ExhaustRuntime.__examine(
                    gen,
                    settings: [.severity(.silent), .reflection(.warning)],
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
