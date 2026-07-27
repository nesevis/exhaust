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
                await #execute(BoundedQueueSpec.self, mode: .sequential, .commandLimit(20))
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatch(
                    BoundedQueueSpec.self,
                    mode: .sequential,
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
                await #execute(Spec.self, mode: .sequential, .commandLimit(20), .budget(.thorough))
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatch(
                    Spec.self,
                    mode: .sequential,
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
                await #execute(Spec.self, mode: .sequential)
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatch(
                    Spec.self,
                    mode: .sequential,
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        /// The mode reaches the runtime as written, and the settings variadic keeps its own place in the expansion.
        @Test("#execute forwards a mode and keeps the settings apart from it")
        func executeStateMachineWithMode() {
            assertMacro {
                """
                await #execute(Spec.self, mode: .tasks, .commandLimit(6))
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatch(
                    Spec.self,
                    mode: .tasks,
                    settings: [.commandLimit(6)],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        /// A mode the call site computed cannot be read at expansion time, so it is forwarded verbatim and the checks that depend on knowing it fall to the runtime.
        @Test("#execute forwards a computed mode verbatim")
        func executeStateMachineWithComputedMode() {
            assertMacro {
                """
                await #execute(Spec.self, mode: chosenMode)
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatch(
                    Spec.self,
                    mode: chosenMode,
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

        /// Every overload declares `mode:`, so a call without one has already failed overload resolution. The expansion refuses rather than defaulting, because a silently sequential run is the one outcome a forgotten mode must never produce — a spec whose commands are async would run, test strictly less than intended, and pass.
        @Test("Missing mode produces error rather than a silent sequential run")
        func missingMode() {
            assertMacro {
                """
                await #execute(Spec.self, .commandLimit(6))
                """
            } diagnostics: {
                """
                await #execute(Spec.self, .commandLimit(6))
                      ┬────────────────────────────────────
                      ╰─ 🛑 #execute requires a 'mode:' argument (.sequential, .tasks, or .threads)
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
                await #execute(AsyncSpec.self, mode: .sequential)
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatchAsync(
                    AsyncSpec.self,
                    mode: .sequential,
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
                await #execute(AsyncSpec.self, mode: .sequential, .commandLimit(10), .parallelize(lanes: .three))
                """
            } expansion: {
                """
                await __ExhaustRuntime.__runStateMachineDispatchAsync(
                    AsyncSpec.self,
                    mode: .sequential,
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
