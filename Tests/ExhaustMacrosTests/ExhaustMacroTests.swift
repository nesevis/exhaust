#if os(macOS)
    import MacroTesting
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "#exhaust macro expansion tests",
        .macros(["exhaust": ExhaustTestMacro.self], record: .failed)
    )
    struct ExhaustMacroTests {
        @Test("Basic exhaust with trailing closure captures source")
        func basicExhaust() {
            assertMacro {
                """
                #exhaust(personGen) { person in
                    person.age >= 0
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaust(
                    personGen,
                    settings: [],

                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { person in
                    person.age >= 0
                    }
                )
                """
            }
        }

        @Test("Exhaust with settings and trailing closure")
        func exhaustWithSettings() {
            assertMacro {
                """
                #exhaust(personGen, .maxIterations(1000), .replay(42)) { person in
                    person.age >= 0
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaust(
                    personGen,
                    settings: [.maxIterations(1000), .replay(42)],

                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { person in
                    person.age >= 0
                    }
                )
                """
            }
        }

        @Test("Function reference expansion")
        func functionReference() {
            assertMacro {
                """
                #exhaust(personGen, property: isValid)
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaust(
                    personGen,
                    settings: [],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: isValid
                )
                """
            }
        }

        @Test("Function reference with settings")
        func functionReferenceWithSettings() {
            assertMacro {
                """
                #exhaust(personGen, .maxIterations(500), property: isValid)
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaust(
                    personGen,
                    settings: [.maxIterations(500)],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: isValid
                )
                """
            }
        }

        // MARK: - Issue.record Rewriting

        @Test("Single Issue.record() routes to void path with detection closure")
        func issueRecordSingleStatement() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    Issue.record()
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaustExpect(
                    gen,
                    settings: [],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { value in
                    Issue.record()
                    },
                    detection: { value in
                    try __ExhaustRuntime.__detectRequire(false)
                    }
                )
                """
            }
        }

        @Test("Issue.record alongside #expect rewrites both in detection closure")
        func issueRecordWithExpect() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    if value < 0 {
                        Issue.record("negative")
                    }
                    #expect(value > 0)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaustExpect(
                    gen,
                    settings: [],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { value in
                    if value < 0 {
                        Issue.record("negative")
                    }
                    #expect(value > 0, sourceLocation: Testing.SourceLocation(fileID: "TestModule/Test.swift", filePath: "Test.swift", line: 5, column: 5))
                    },
                    detection: { value in
                    if value < 0 {
                        try __ExhaustRuntime.__detectRequire(false)
                    }
                    try __ExhaustRuntime.__detectRequire(value > 0)
                    }
                )
                """
            }
        }

        // MARK: - Vacuous Void Closure Detection

        @Test("Single-statement switch expression routes to Bool path")
        func switchExpressionBoolPath() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    switch value {
                    case 1: true
                    case 2: false
                    default: false
                    }
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaust(
                    gen,
                    settings: [],

                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { value in
                    switch value {
                    case 1:
                        true
                    case 2:
                        false
                    default:
                        false
                    }
                    }
                )
                """
            }
        }

        @Test("Single-statement switch with #expect routes to Void path")
        func switchWithExpectVoidPath() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    switch value {
                    case 1: #expect(value > 0)
                    default: #expect(value != 0)
                    }
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaustExpect(
                    gen,
                    settings: [],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { value in
                    switch value {
                    case 1:
                        #expect(value > 0, sourceLocation: Testing.SourceLocation(fileID: "TestModule/Test.swift", filePath: "Test.swift", line: 3, column: 13))
                    default:
                        #expect(value != 0, sourceLocation: Testing.SourceLocation(fileID: "TestModule/Test.swift", filePath: "Test.swift", line: 4, column: 14))
                    }
                    },
                    detection: { value in
                    switch value {
                    case 1:
                        try __ExhaustRuntime.__detectRequire(value > 0)
                    default:
                        try __ExhaustRuntime.__detectRequire(value != 0)
                    }
                    }
                )
                """
            }
        }

        @Test("Multi-statement closure with no failure mechanism emits diagnostic")
        func vacuousClosureDiscardedComparison() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    let box = ThreadSafeBox(0)
                    box.put(value)
                    box.get() == value
                }
                """
            } diagnostics: {
                """
                #exhaust(gen) { value in
                              ╰─ 🛑 Closure has no failure mechanism; return a Bool or throw an error to signal failure
                    let box = ThreadSafeBox(0)
                    box.put(value)
                    box.get() == value
                }
                """
            }
        }

        @Test("Multi-statement closure with only void calls emits diagnostic")
        func vacuousClosureVoidCalls() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    doSomething()
                    doSomethingElse(value)
                }
                """
            } diagnostics: {
                """
                #exhaust(gen) { value in
                              ╰─ 🛑 Closure has no failure mechanism; return a Bool or throw an error to signal failure
                    doSomething()
                    doSomethingElse(value)
                }
                """
            }
        }

        @Test("Multi-statement closure with try has failure mechanism — no diagnostic")
        func tryIsFailureMechanism() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    let result = try compute(value)
                    use(result)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaustExpect(
                    gen,
                    settings: [],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { value in
                    let result = try compute(value)
                    use(result)
                    },
                    detection: { value in
                    let result = try compute(value)
                    use(result)
                    }
                )
                """
            }
        }

        @Test("Multi-statement closure with try? has no failure mechanism — emits diagnostic")
        func tryQuestionIsNotFailureMechanism() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    let result = try? compute(value)
                    use(result)
                }
                """
            } diagnostics: {
                """
                #exhaust(gen) { value in
                              ╰─ 🛑 Closure has no failure mechanism; return a Bool or throw an error to signal failure
                    let result = try? compute(value)
                    use(result)
                }
                """
            }
        }

        @Test("Multi-statement closure with throw has failure mechanism — no diagnostic")
        func throwIsFailureMechanism() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    if value < 0 {
                        throw TestError()
                    }
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaustExpect(
                    gen,
                    settings: [],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { value in
                    if value < 0 {
                        throw TestError()
                    }
                    },
                    detection: { value in
                    if value < 0 {
                        throw TestError()
                    }
                    }
                )
                """
            }
        }

        @Test("Multi-statement closure with explicit return does not emit diagnostic")
        func explicitReturnNoDiagnostic() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    let x = compute(value)
                    return x == 0
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaust(
                    gen,
                    settings: [],

                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { value in
                    let x = compute(value)
                    return x == 0
                    }
                )
                """
            }
        }

        @Test("Single-expression closure with comparison does not emit diagnostic")
        func singleExpressionNoDiagnostic() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    value == 0
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaust(
                    gen,
                    settings: [],

                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { value in
                    value == 0
                    }
                )
                """
            }
        }

        @Test("Multi-statement closure with #expect has failure mechanism — no diagnostic")
        func expectIsFailureMechanism() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    let x = compute(value)
                    #expect(x == 0)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaustExpect(
                    gen,
                    settings: [],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { value in
                    let x = compute(value)
                    #expect(x == 0, sourceLocation: Testing.SourceLocation(fileID: "TestModule/Test.swift", filePath: "Test.swift", line: 3, column: 5))
                    },
                    detection: { value in
                    let x = compute(value)
                    try __ExhaustRuntime.__detectRequire(x == 0)
                    }
                )
                """
            }
        }

        @Test("Multi-statement closure with Issue.record has failure mechanism — no diagnostic")
        func issueRecordIsFailureMechanism() {
            assertMacro {
                """
                #exhaust(gen) { value in
                    if value < 0 {
                        Issue.record("negative")
                    }
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaustExpect(
                    gen,
                    settings: [],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { value in
                    if value < 0 {
                        Issue.record("negative")
                    }
                    },
                    detection: { value in
                    if value < 0 {
                        try __ExhaustRuntime.__detectRequire(false)
                    }
                    }
                )
                """
            }
        }

        // MARK: - Error Diagnostics

        @Test("Missing property produces error")
        func missingProperty() {
            assertMacro {
                """
                #exhaust(personGen)
                """
            } diagnostics: {
                """
                #exhaust(personGen)
                ┬──────────────────
                ╰─ 🛑 #exhaust requires a property (trailing closure or 'property:' argument)
                """
            }
        }
    }

    // MARK: - Async Expansion Tests

    @Suite(
        "#exhaust async macro expansion tests",
        .macros(["exhaust": ExhaustAsyncTestMacro.self], record: .failed)
    )
    struct ExhaustAsyncMacroTests {
        @Test("Async Bool trailing closure expands to __exhaustAsync")
        func asyncBoolTrailingClosure() {
            assertMacro {
                """
                #exhaust(personGen) { person in
                    await actor.validate(person)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaustAsync(
                    personGen,
                    settings: [],

                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { person in
                    await actor.validate(person)
                    }
                )
                """
            }
        }

        @Test("Async Void trailing closure with #expect expands to __exhaustExpectAsync")
        func asyncVoidTrailingClosure() {
            assertMacro {
                """
                #exhaust(personGen) { person in
                    let result = await actor.validate(person)
                    #expect(result)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaustExpectAsync(
                    personGen,
                    settings: [],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: { person in
                    let result = await actor.validate(person)
                    #expect(result, sourceLocation: Testing.SourceLocation(fileID: "TestModule/Test.swift", filePath: "Test.swift", line: 3, column: 5))
                    },
                    detection: { person in
                    let result = await actor.validate(person)
                    try __ExhaustRuntime.__detectRequire(result)
                    }
                )
                """
            }
        }

        @Test("Async function reference expands to __exhaustAsync")
        func asyncFunctionReference() {
            assertMacro {
                """
                #exhaust(personGen, property: asyncIsValid)
                """
            } expansion: {
                """
                __ExhaustRuntime.__exhaustAsync(
                    personGen,
                    settings: [],


                    fileID: #fileID,
                    filePath: #filePath,
                    line: #line,
                    column: #column,
                    function: #function,
                    property: asyncIsValid
                )
                """
            }
        }
    }
#endif
