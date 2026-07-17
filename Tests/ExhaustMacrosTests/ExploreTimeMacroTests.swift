#if os(macOS)
    import MacroTesting
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "#explore(time:) macro expansion tests",
        .macros(["explore": ExploreTimeMacro.self], record: .failed)
    )
    struct ExploreTimeMacroTests {
        @Test("Bool trailing closure expands to __exploreTime")
        func boolTrailingClosure() {
            assertMacro {
                """
                #explore(messageGen, time: .minutes(15)) { message in
                    message.isValid
                }
                """
            } diagnostics: {
                """
                #explore(messageGen, time: .minutes(15)) { message in
                ╰─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                    message.isValid
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exploreTime(
                    messageGen,
                    time: .minutes(15),
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    property: { message in
                    message.isValid
                    }
                )
                """
            }
        }

        @Test("Settings pass through as an array")
        func settingsPassThrough() {
            assertMacro {
                """
                #explore(messageGen, time: .seconds(30), .replay(42), .suppress(.all)) { message in
                    message.isValid
                }
                """
            } diagnostics: {
                """
                #explore(messageGen, time: .seconds(30), .replay(42), .suppress(.all)) { message in
                ╰─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                    message.isValid
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exploreTime(
                    messageGen,
                    time: .seconds(30),
                    settings: [.replay(42), .suppress(.all)],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    property: { message in
                    message.isValid
                    }
                )
                """
            }
        }

        @Test("Void closure with #expect expands to __exploreTimeExpect with a detection rewrite")
        func expectClosure() {
            assertMacro {
                """
                #explore(messageGen, time: .minutes(2)) { message in
                    let decoded = try Decoder.decode(message)
                    #expect(decoded.isValid)
                }
                """
            } diagnostics: {
                """
                #explore(messageGen, time: .minutes(2)) { message in
                ╰─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                    let decoded = try Decoder.decode(message)
                    #expect(decoded.isValid)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exploreTimeExpect(
                    messageGen,
                    time: .minutes(2),
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    property: { message in
                    let decoded = try Decoder.decode(message)
                    #expect(decoded.isValid, sourceLocation: Testing.SourceLocation(fileID: "TestModule/Test.swift", filePath: "Test.swift", line: 3, column: 5))
                    },
                    detection: { message in
                    let decoded = try Decoder.decode(message)
                    try __ExhaustRuntime.__detectRequire(decoded.isValid)
                    }
                )
                """
            }
        }

        @Test("Function reference expands to __exploreTime")
        func functionReference() {
            assertMacro {
                """
                #explore(messageGen, time: .minutes(5), property: checkMessage)
                """
            } diagnostics: {
                """
                #explore(messageGen, time: .minutes(5), property: checkMessage)
                ┬──────────────────────────────────────────────────────────────
                ╰─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                """
            } expansion: {
                """
                __ExhaustRuntime.__exploreTime(
                    messageGen,
                    time: .minutes(5),
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    property: checkMessage
                )
                """
            }
        }

        @Test("Combining time: and directions: is diagnosed")
        func directionsConflict() {
            assertMacro {
                """
                #explore(messageGen, time: .minutes(5), directions: [("north", { $0 > 0 })]) { message in
                    message.isValid
                }
                """
            } diagnostics: {
                """
                #explore(messageGen, time: .minutes(5), directions: [("north", { $0 > 0 })]) { message in
                                                                    ┬──────────────────────
                │                                                   ╰─ 🛑 #explore cannot combine 'time:' and 'directions:'; the modes are mutually exclusive. Use 'time:' for a coverage-guided fuzz run or 'directions:' for goal-bounded exploration
                ╰─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                    message.isValid
                }
                """
            }
        }

        @Test("Missing time: is diagnosed")
        func missingTime() {
            assertMacro {
                """
                #explore(messageGen) { message in
                    message.isValid
                }
                """
            } diagnostics: {
                """
                #explore(messageGen) { message in
                ├─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                ╰─ 🛑 #explore(time:) requires a 'time:' argument
                    message.isValid
                }
                """
            }
        }
    }

    @Suite(
        "#explore(time:) async macro expansion tests",
        .macros(["explore": ExploreTimeAsyncMacro.self], record: .failed)
    )
    struct ExploreTimeAsyncMacroTests {
        @Test("Async Bool trailing closure expands to __exploreTimeAsync")
        func asyncBoolClosure() {
            assertMacro {
                """
                #explore(messageGen, time: .minutes(15)) { message in
                    await server.accepts(message)
                }
                """
            } diagnostics: {
                """
                #explore(messageGen, time: .minutes(15)) { message in
                ╰─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                    await server.accepts(message)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exploreTimeAsync(
                    messageGen,
                    time: .minutes(15),
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    property: { message in
                    await server.accepts(message)
                    }
                )
                """
            }
        }

        @Test("Async Void closure with #expect expands to __exploreTimeExpectAsync with a detection rewrite")
        func asyncExpectClosure() {
            assertMacro {
                """
                #explore(messageGen, time: .minutes(2)) { message in
                    let response = try await server.roundTrip(message)
                    #expect(response.isAcknowledgement)
                }
                """
            } diagnostics: {
                """
                #explore(messageGen, time: .minutes(2)) { message in
                ╰─ ⚠️ #explore(time:) is experimental: its settings, report format, and search behavior may change in any release
                    let response = try await server.roundTrip(message)
                    #expect(response.isAcknowledgement)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exploreTimeExpectAsync(
                    messageGen,
                    time: .minutes(2),
                    settings: [],
                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    property: { message in
                    let response = try await server.roundTrip(message)
                    #expect(response.isAcknowledgement, sourceLocation: Testing.SourceLocation(fileID: "TestModule/Test.swift", filePath: "Test.swift", line: 3, column: 5))
                    },
                    detection: { message in
                    let response = try await server.roundTrip(message)
                    try __ExhaustRuntime.__detectRequire(response.isAcknowledgement)
                    }
                )
                """
            }
        }
    }
#endif
