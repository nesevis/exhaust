#if os(macOS)
    import MacroTesting
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "#explore(Spec.self, time:) macro expansion tests",
        .macros(["explore": ExploreSpecTimeMacro.self], record: .failed)
    )
    struct ExploreSpecTimeMacroTests {
        @Test("Sync spec expands to __runStateMachineTimeDispatch")
        func syncSpec() {
            assertMacro {
                """
                #explore(BoundedQueueSpec.self, mode: .sequential, time: .minutes(5))
                """
            } diagnostics: {
                """
                #explore(BoundedQueueSpec.self, mode: .sequential, time: .minutes(5))
                ┬────────────────────────────────────────────────────────────────────
                ╰─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                """
            } expansion: {
                """
                __ExhaustRuntime.__runStateMachineTimeDispatch(
                    BoundedQueueSpec.self,
                    mode: .sequential,
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
                #explore(BoundedQueueSpec.self)
                """
            } diagnostics: {
                """
                #explore(BoundedQueueSpec.self)
                ┬──────────────────────────────
                ├─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                ╰─ 🛑 #explore(time:) requires a 'time:' argument
                """
            }
        }

        /// Every overload declares `mode:`, so a call without one has already failed overload resolution. The expansion still names it rather than defaulting, because a silently sequential run is the one outcome a forgotten mode must never produce.
        @Test("Missing mode: is diagnosed rather than defaulted")
        func missingMode() {
            assertMacro {
                """
                #explore(BoundedQueueSpec.self, time: .minutes(5))
                """
            } diagnostics: {
                """
                #explore(BoundedQueueSpec.self, time: .minutes(5))
                ┬─────────────────────────────────────────────────
                ├─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                ╰─ 🛑 #explore requires a 'mode:' argument (.sequential or .tasks)
                """
            }
        }

        @Test("Async macro expands to __runStateMachineTimeDispatchAsync")
        func asyncSpec() {
            withMacroTesting(macros: ["explore": ExploreSpecTimeAsyncMacro.self]) {
                assertMacro {
                    """
                    #explore(ConcurrentQueueSpec.self, mode: .sequential, time: .minutes(5), .parallelize(lanes: .two))
                    """
                } diagnostics: {
                    """
                    #explore(ConcurrentQueueSpec.self, mode: .sequential, time: .minutes(5), .parallelize(lanes: .two))
                    ┬──────────────────────────────────────────────────────────────────────────────────────────────────
                    ╰─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                    """
                } expansion: {
                    """
                    __ExhaustRuntime.__runStateMachineTimeDispatchAsync(
                        ConcurrentQueueSpec.self,
                        mode: .sequential,
                        time: .minutes(5),
                        settings: [.parallelize(lanes: .two)],
                        fileID: #fileID,
                        filePath: #filePath,
                        line: #line,
                        column: #column
                    )
                    """
                }
            }
        }

        @Test("Settings pass through as an array")
        func settingsPassThrough() {
            assertMacro {
                """
                #explore(BoundedQueueSpec.self, mode: .sequential, time: .seconds(30), .replay(42))
                """
            } diagnostics: {
                """
                #explore(BoundedQueueSpec.self, mode: .sequential, time: .seconds(30), .replay(42))
                ┬──────────────────────────────────────────────────────────────────────────────────
                ╰─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                """
            } expansion: {
                """
                __ExhaustRuntime.__runStateMachineTimeDispatch(
                    BoundedQueueSpec.self,
                    mode: .sequential,
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
