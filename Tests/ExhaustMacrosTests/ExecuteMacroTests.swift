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
                #execute(BoundedQueueContract.self, .commandLimit(20))
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContractDispatch(
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
                #execute(Spec.self, .commandLimit(20), .budget(.thorough))
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContractDispatch(
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
                #execute(Spec.self)
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContractDispatch(
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
                #execute()
                """
            } diagnostics: {
                """
                #execute()
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
                #execute(AsyncSpec.self)
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContractDispatchAsync(
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
                #execute(AsyncSpec.self, .commandLimit(10), .concurrent(.three))
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContractDispatchAsync(
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
