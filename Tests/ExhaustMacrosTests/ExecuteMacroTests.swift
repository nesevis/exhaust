#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "#execute sync spec macro expansion tests",
        .macros(["execute": ExhaustStateMachineMacro.self], record: .failed)
    )
    struct ExecuteStateMachineMacroTests {
        @Test("#execute sync spec expansion with commandLimit")
        func executeStateMachineWithCommandLimit() {
            assertMacro {
                """
                await #execute(BoundedQueueSpec.self, .commandLimit(20))
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatch(
                    BoundedQueueSpec.self,
                    settings: [.commandLimit(20)],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("#execute sync spec with multiple settings")
        func executeStateMachineWithSettings() {
            assertMacro {
                """
                await #execute(Spec.self, .commandLimit(20), .budget(.thorough))
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatch(
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

        @Test("#execute sync spec with no settings")
        func executeStateMachineWithNoSettings() {
            assertMacro {
                """
                await #execute(Spec.self)
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatch(
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
        "#execute async spec macro expansion tests",
        .macros(["execute": ExhaustAsyncStateMachineMacro.self], record: .failed)
    )
    struct ExecuteAsyncStateMachineMacroTests {
        @Test("#execute async spec expansion with no settings")
        func executeAsyncStateMachineWithNoSettings() {
            assertMacro {
                """
                await #execute(AsyncSpec.self)
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatchAsync(
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

        @Test("#execute async spec with settings")
        func executeAsyncStateMachineWithSettings() {
            assertMacro {
                """
                await #execute(AsyncSpec.self, .commandLimit(10), .parallelize(lanes: .three))
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatchAsync(
                    AsyncSpec.self,
                    settings: [.commandLimit(10), .parallelize(lanes: .three)],
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
