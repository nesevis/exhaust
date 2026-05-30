#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "#execute contract macro expansion tests",
        .macros(["execute": ExhaustContractMacro.self], record: .failed)
    )
    struct ExecuteContractMacroTests {
        @Test("Basic #execute contract expansion with commandLimit")
        func basicExecuteContractExpansionWithCommandLimit() {
            assertMacro {
                """
                #execute(BoundedQueueSpec.self, .commandLimit(20))
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContract(
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

        @Test("#execute contract with settings")
        func executeContractWithSettings() {
            assertMacro {
                """
                #execute(Spec.self, .commandLimit(20), .budget(.thorough))
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContract(
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

        @Test("#execute contract with no settings")
        func executeContractWithNoSettings() {
            assertMacro {
                """
                #execute(Spec.self)
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContract(
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

        @Test("#execute contract with suppress only")
        func executeContractWithSuppressOnly() {
            assertMacro {
                """
                #execute(Spec.self, .suppress(.issueReporting))
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContract(
                    Spec.self,
                    settings: [.suppress(.issueReporting)],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        // MARK: - Error Diagnostics

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
        .macros(["execute": ExhaustConcurrentContractMacro.self], record: .failed)
    )
    struct ExecuteAsyncContractMacroTests {
        @Test("#execute async contract expansion with no settings")
        func executeAsyncContractExpansionWithNoSettings() {
            assertMacro {
                """
                #execute(AsyncSpec.self)
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContractConcurrent(
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
                #execute(AsyncSpec.self, .commandLimit(10), .concurrent(3))
                """
            } expansion: {
                """
                __ExhaustRuntime.__runContractConcurrent(
                    AsyncSpec.self,
                    settings: [.commandLimit(10), .concurrent(3)],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }
    }

    @Suite(
        "#execute GCD concurrent contract macro expansion tests",
        .macros(["execute": ExhaustGCDContractMacro.self], record: .failed)
    )
    struct ExecuteGCDContractMacroTests {
        @Test("#execute sync concurrent contract expansion with no settings")
        func executeSyncConcurrentContractExpansionWithNoSettings() {
            assertMacro {
                """
                #execute(CounterSpec.self)
                """
            } expansion: {
                """
                await __ExhaustRuntime.dispatchToGCD {
                    __ExhaustRuntime.__runPreemptiveConcurrentContract(
                        CounterSpec.self,
                        settings: [],
                        fileID: #fileID,
                        filePath: #filePath,
                        line: #line,
                        column: #column
                    )
                }
                """
            }
        }

        @Test("#execute sync concurrent contract with settings")
        func executeSyncConcurrentContractWithSettings() {
            assertMacro {
                """
                #execute(CounterSpec.self, .concurrent(2), .commandLimit(6))
                """
            } expansion: {
                """
                await __ExhaustRuntime.dispatchToGCD {
                    __ExhaustRuntime.__runPreemptiveConcurrentContract(
                        CounterSpec.self,
                        settings: [.concurrent(2), .commandLimit(6)],
                        fileID: #fileID,
                        filePath: #filePath,
                        line: #line,
                        column: #column
                    )
                }
                """
            }
        }
    }

    @Suite(
        "#execute async GCD concurrent contract macro expansion tests",
        .macros(["execute": ExhaustAsyncGCDContractMacro.self], record: .failed)
    )
    struct ExecuteAsyncGCDContractMacroTests {
        @Test("#execute async concurrent contract expansion with no settings")
        func executeAsyncConcurrentContractExpansionWithNoSettings() {
            assertMacro {
                """
                #execute(AsyncCounterSpec.self)
                """
            } expansion: {
                """
                __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
                    AsyncCounterSpec.self,
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("#execute async concurrent contract with settings")
        func executeAsyncConcurrentContractWithSettings() {
            assertMacro {
                """
                #execute(AsyncCounterSpec.self, .concurrent(2), .budget(.quick))
                """
            } expansion: {
                """
                __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
                    AsyncCounterSpec.self,
                    settings: [.concurrent(2), .budget(.quick)],
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
