#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "#execute sync contract macro expansion tests",
        .macros(["execute": ExhaustContractMacro.self], record: .failed)
    )
    struct ExecuteContractMacroTests {
        @Test("#execute sync contract expansion with commandLimit")
        func executeContractWithCommandLimit() {
            assertMacro {
                """
                await #execute(BoundedQueueContract.self, .commandLimit(20))
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runContractDispatch(
                    BoundedQueueContract.self,
                    settings: [.commandLimit(20)],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("#execute sync contract with multiple settings")
        func executeContractWithSettings() {
            assertMacro {
                """
                await #execute(Spec.self, .commandLimit(20), .budget(.thorough))
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runContractDispatch(
                    Spec.self,
                    settings: [.commandLimit(20), .budget(.thorough)],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("#execute sync contract with no settings")
        func executeContractWithNoSettings() {
            assertMacro {
                """
                await #execute(Spec.self)
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runContractDispatch(
                    Spec.self,
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Missing spec produces error")
        func missingSpec() {
            assertMacro {
                """
                await #execute()
                """
            } diagnostics: {
                """
                await #execute()
                      ┬─────────
                      ╰─ 🛑 #execute requires a spec type argument
                """
            }
        }
    }

    @Suite(
        "#execute async contract macro expansion tests",
        .macros(["execute": ExhaustAsyncContractMacro.self], record: .failed)
    )
    struct ExecuteAsyncContractMacroTests {
        @Test("#execute async contract expansion with no settings")
        func executeAsyncContractWithNoSettings() {
            assertMacro {
                """
                await #execute(AsyncSpec.self)
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runContractDispatchAsync(
                    AsyncSpec.self,
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("#execute async contract with settings")
        func executeAsyncContractWithSettings() {
            assertMacro {
                """
                await #execute(AsyncSpec.self, .commandLimit(10), .concurrent(.three))
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runContractDispatchAsync(
                    AsyncSpec.self,
                    settings: [.commandLimit(10), .concurrent(.three)],
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
