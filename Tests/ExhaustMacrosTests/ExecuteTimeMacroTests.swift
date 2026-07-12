#if os(macOS)
    import MacroTesting
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "#execute(time:) macro expansion tests",
        .macros(["execute": ExecuteTimeMacro.self], record: .failed)
    )
    struct ExecuteTimeMacroTests {
        @Test("Sync spec expands to __runStateMachineTimeDispatch")
        func syncSpec() {
            assertMacro {
                """
                #execute(BoundedQueueSpec.self, time: .minutes(5))
                """
            } diagnostics: {
                """
                #execute(BoundedQueueSpec.self, time: .minutes(5))
                ┬─────────────────────────────────────────────────
                ╰─ ⚠️ #execute(time:) is experimental: its settings, report format, and search behavior may change in any release
                """
            } expansion: {
                """
                __ExhaustRuntime.__runStateMachineTimeDispatch(
                    BoundedQueueSpec.self,
                    time: .minutes(5),
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column
                )
                """
            }
        }

        @Test("Missing time: is diagnosed")
        func missingTime() {
            assertMacro {
                """
                #execute(BoundedQueueSpec.self)
                """
            } diagnostics: {
                """
                #execute(BoundedQueueSpec.self)
                ┬──────────────────────────────
                ├─ ⚠️ #execute(time:) is experimental: its settings, report format, and search behavior may change in any release
                ╰─ 🛑 #execute(time:) requires a 'time:' argument
                """
            }
        }

        @Test("Settings pass through as an array")
        func settingsPassThrough() {
            assertMacro {
                """
                #execute(BoundedQueueSpec.self, time: .seconds(30), .replay(42))
                """
            } diagnostics: {
                """
                #execute(BoundedQueueSpec.self, time: .seconds(30), .replay(42))
                ┬───────────────────────────────────────────────────────────────
                ╰─ ⚠️ #execute(time:) is experimental: its settings, report format, and search behavior may change in any release
                """
            } expansion: {
                """
                __ExhaustRuntime.__runStateMachineTimeDispatch(
                    BoundedQueueSpec.self,
                    time: .seconds(30),
                    settings: [.replay(42)],
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
