#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    private nonisolated(unsafe) let testMacros: [String: any Macro.Type] = [
        "exhaust": ExhaustContractMacro.self,
        "Contract": ContractDeclarationMacro.self,
        "Model": ModelMacro.self,
        "SystemUnderTest": SUTMacro.self,
        "Command": CommandMacro.self,
        "Invariant": InvariantMacro.self,
    ]

    private nonisolated(unsafe) let asyncTestMacros: [String: any Macro.Type] = [
        "exhaust": ExhaustConcurrentContractMacro.self,
        "Contract": ContractDeclarationMacro.self,
        "Model": ModelMacro.self,
        "SystemUnderTest": SUTMacro.self,
        "Command": CommandMacro.self,
        "Invariant": InvariantMacro.self,
    ]

    @Suite(
        "#exhaust contract macro expansion tests",
        .macros(testMacros, record: .failed)
    )
    struct ContractMacroTests {
        @Test("Basic #exhaust contract expansion with commandLimit")
        func basicExhaustContractExpansionWithCommandLimit() {
            assertMacro {
                """
                #exhaust(BoundedQueueSpec.self, .commandLimit(20))
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

        @Test("#exhaust contract with settings")
        func exhaustContractWithSettings() {
            assertMacro {
                """
                #exhaust(Spec.self, .commandLimit(20), .budget(.thorough))
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

        @Test("#exhaust contract with no settings")
        func exhaustContractWithNoSettings() {
            assertMacro {
                """
                #exhaust(Spec.self)
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

        @Test("#exhaust contract with suppress only")
        func exhaustContractWithSuppressOnly() {
            assertMacro {
                """
                #exhaust(Spec.self, .suppress(.issueReporting))
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
    }

    @Suite(
        "@Contract declaration macro tests",
        .macros(testMacros, record: .failed)
    )
    struct ContractDeclarationMacroTests {
        @Test("Synthesizes Command enum, SUT typealias, and conformance")
        func synthesizesCommandEnumSUTTypealiasAndConformance() {
            assertMacro {
                """
                @Contract
                struct QueueSpec {
                    @Model var contents: [Int] = []
                    @SystemUnderTest var queue: MyQueue

                    @Command(weight: 3)
                    mutating func enqueue(value: Int) throws {
                    }

                    @Command(weight: 2)
                    mutating func dequeue() throws {
                    }

                    @Invariant
                    func countMatches() -> Bool {
                        true
                    }
                }
                """
            } diagnostics: {
                """
                @Contract
                struct QueueSpec {
                    @Model var contents: [Int] = []
                    @SystemUnderTest var queue: MyQueue

                    @Command(weight: 3)
                    ╰─ 🛑 @Command method has parameters but no generator expressions — add generators to the @Command attribute
                    mutating func enqueue(value: Int) throws {
                    }

                    @Command(weight: 2)
                    mutating func dequeue() throws {
                    }

                    @Invariant
                    func countMatches() -> Bool {
                        true
                    }
                }
                """
            }
        }

        @Test("Marker macros produce no peer declarations")
        func markerMacrosProduceNoPeerDeclarations() {
            assertMacro {
                """
                @Model var x: Int = 0
                """
            } expansion: {
                """
                var x: Int = 0
                """
            }
        }

        @Test("Async command produces AsyncContractSpec conformance and async run/checkInvariants")
        func asyncCommandProducesAsyncContractSpecConformanceAndAsyncRuncheckInvariants() {
            assertMacro {
                """
                @Contract
                struct AsyncSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 1)
                    mutating func increment() async throws {
                    }

                    @Command(weight: 1)
                    mutating func decrement() throws {
                    }

                    @Invariant
                    func isValid() -> Bool {
                        true
                    }
                }
                """
            } diagnostics: {
                """
                @Contract
                ┬────────
                ╰─ 🛑 @Contract with async commands or invariants must be a class — use 'final class' instead of 'struct'
                struct AsyncSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 1)
                    mutating func increment() async throws {
                    }

                    @Command(weight: 1)
                    mutating func decrement() throws {
                    }

                    @Invariant
                    func isValid() -> Bool {
                        true
                    }
                }
                """
            }
        }

        @Test("Async invariant produces AsyncContractSpec conformance")
        func asyncInvariantProducesAsyncContractSpecConformance() {
            assertMacro {
                """
                @Contract
                struct AsyncInvSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 1)
                    mutating func increment() throws {
                    }

                    @Invariant
                    func isValid() async -> Bool {
                        true
                    }
                }
                """
            } diagnostics: {
                """
                @Contract
                ┬────────
                ╰─ 🛑 @Contract with async commands or invariants must be a class — use 'final class' instead of 'struct'
                struct AsyncInvSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 1)
                    mutating func increment() throws {
                    }

                    @Invariant
                    func isValid() async -> Bool {
                        true
                    }
                }
                """
            }
        }

        @Test("All-sync commands still produce ContractSpec conformance")
        func allSyncCommandsStillProduceContractSpecConformance() {
            assertMacro {
                """
                @Contract
                struct SyncSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 1)
                    mutating func increment() throws {
                    }
                }
                """
            } expansion: {
                #"""
                struct SyncSpec {
                    var counter: MyCounter
                    mutating func increment() throws {
                    }

                    enum Command: CustomStringConvertible, Sendable {
                            case increment

                        var description: String {
                            switch self {
                                case .increment:
                                "increment"
                            }
                        }
                    }

                    typealias SystemUnderTest = MyCounter

                    var systemUnderTest: SystemUnderTest {
                        counter
                    }

                    static var commandGenerator: ReflectiveGenerator<Command> {
                        .oneOf(weighted:
                                (1, .just(Command.increment))
                        )
                    }

                    mutating func run(_ command: Command) throws {
                        switch command {
                            case .increment:
                            try self.increment()
                        }
                    }

                    func checkInvariants() throws {
                    }

                    var modelDescription: String {
                        "(no model properties)"
                    }

                    var sutDescription: String {
                        "counter: \(counter)"
                    }
                }

                extension SyncSpec: ContractSpec {
                }
                """#
            }
        }

        @Test("@Command with generator expression produces #gen in commandGenerator")
        func commandWithGeneratorExpressionProducesGenInCommandGenerator() {
            assertMacro {
                """
                @Contract
                struct InsertSpec {
                    @SystemUnderTest var items: [Int]

                    @Command(weight: 3, .int(in: 0...99))
                    mutating func insert(value: Int) throws {
                    }
                }
                """
            } expansion: {
                #"""
                struct InsertSpec {
                    var items: [Int]
                    mutating func insert(value: Int) throws {
                    }

                    enum Command: CustomStringConvertible, Sendable {
                            case insert(value: Int)

                        var description: String {
                            switch self {
                                case let .insert(value):
                                "insert(\(value))"
                            }
                        }
                    }

                    typealias SystemUnderTest = [Int]

                    var systemUnderTest: SystemUnderTest {
                        items
                    }

                    static var commandGenerator: ReflectiveGenerator<Command> {
                        .oneOf(weighted:
                                (3, #gen((.int(in: 0 ... 99) as ReflectiveGenerator<Int>)) { value in
                                    Command.insert(value: value)
                                })
                        )
                    }

                    mutating func run(_ command: Command) throws {
                        switch command {
                            case let .insert(value):
                            try self.insert(value: value)
                        }
                    }

                    func checkInvariants() throws {
                    }

                    var modelDescription: String {
                        "(no model properties)"
                    }

                    var sutDescription: String {
                        "items: \(items)"
                    }
                }

                extension InsertSpec: ContractSpec {
                }
                """#
            }
        }
    }

    @Suite(
        "@Contract tab indentation tests",
        .macros(testMacros, indentationWidth: .tabs(1), record: .failed)
    )
    struct ContractTabIndentationTests {
        @Test("@Contract with tab indentation synthesizes correctly indented members")
        func contractWithTabIndentationSynthesizesCorrectlyIndentedMembers() {
            assertMacro {
                """
                @Contract
                struct QueueSpec {
                \t@Model var contents: [Int] = []
                \t@SystemUnderTest var queue: MyQueue

                \t@Command(weight: 3)
                \tmutating func enqueue(value: Int) throws {
                \t}

                \t@Command(weight: 2)
                \tmutating func dequeue() throws {
                \t}

                \t@Invariant
                \tfunc countMatches() -> Bool {
                \t\ttrue
                \t}
                }
                """
            } diagnostics: {
                """
                @Contract
                struct QueueSpec {
                	@Model var contents: [Int] = []
                	@SystemUnderTest var queue: MyQueue

                	@Command(weight: 3)
                 ╰─ 🛑 @Command method has parameters but no generator expressions — add generators to the @Command attribute
                	mutating func enqueue(value: Int) throws {
                	}

                	@Command(weight: 2)
                	mutating func dequeue() throws {
                	}

                	@Invariant
                	func countMatches() -> Bool {
                		true
                	}
                }
                """
            }
        }

        @Test("@Contract with tab indentation and generator expressions")
        func contractWithTabIndentationAndGeneratorExpressions() {
            assertMacro {
                """
                @Contract
                struct InsertSpec {
                \t@SystemUnderTest var items: [Int]

                \t@Command(weight: 3, .int(in: 0...99))
                \tmutating func insert(value: Int) throws {
                \t}
                }
                """
            } expansion: {
                #"""
                struct InsertSpec {
                	var items: [Int]
                	mutating func insert(value: Int) throws {
                	}

                	enum Command: CustomStringConvertible, Sendable {
                	        case insert(value: Int)

                	    var description: String {
                	        switch self {
                	            case let .insert(value):
                	        	"insert(\(value))"
                	        }
                	    }
                	}

                	typealias SystemUnderTest = [Int]

                	var systemUnderTest: SystemUnderTest {
                		items
                	}

                	static var commandGenerator: ReflectiveGenerator<Command> {
                	    .oneOf(weighted:
                	            (3, #gen((.int(in: 0 ... 99) as ReflectiveGenerator<Int>)) { value in
                	    			Command.insert(value: value)
                	    		})
                	    )
                	}

                	mutating func run(_ command: Command) throws {
                	    switch command {
                	        case let .insert(value):
                	    	try self.insert(value: value)
                	    }
                	}

                	func checkInvariants() throws {
                	}

                	var modelDescription: String {
                		"(no model properties)"
                	}

                	var sutDescription: String {
                		"items: \(items)"
                	}
                }

                extension InsertSpec: ContractSpec {
                }
                """#
            }
        }

        @Test("@Contract with tab indentation and multiple model properties")
        func contractWithTabIndentationAndMultipleModelProperties() {
            assertMacro {
                """
                @Contract
                struct Spec {
                \t@Model var count: Int = 0
                \t@Model var name: String = ""
                \t@SystemUnderTest var sut: MySUT

                \t@Command(weight: 1)
                \tmutating func doSomething() throws {
                \t}
                }
                """
            } expansion: {
                #"""
                struct Spec {
                	var count: Int = 0
                	var name: String = ""
                	var sut: MySUT
                	mutating func doSomething() throws {
                	}

                	enum Command: CustomStringConvertible, Sendable {
                	        case doSomething

                	    var description: String {
                	        switch self {
                	            case .doSomething:
                	        	"doSomething"
                	        }
                	    }
                	}

                	typealias SystemUnderTest = MySUT

                	var systemUnderTest: SystemUnderTest {
                		sut
                	}

                	static var commandGenerator: ReflectiveGenerator<Command> {
                	    .oneOf(weighted:
                	            (1, .just(Command.doSomething))
                	    )
                	}

                	mutating func run(_ command: Command) throws {
                	    switch command {
                	        case .doSomething:
                	    	try self.doSomething()
                	    }
                	}

                	func checkInvariants() throws {
                	}

                	var modelDescription: String {
                		"\n" + [
                		        "  count: \(count)",
                		            "  name: \(name)"
                		    ].joined(separator: "\n")
                	}

                	var sutDescription: String {
                		"sut: \(sut)"
                	}
                }

                extension Spec: ContractSpec {
                }
                """#
            }
        }
    }

    @Suite(
        "#exhaust async contract macro expansion tests",
        .macros(asyncTestMacros, record: .failed)
    )
    struct AsyncContractMacroTests {
        @Test("#exhaust async contract expansion with no settings")
        func exhaustAsyncContractExpansionWithNoSettings() {
            assertMacro {
                """
                #exhaust(AsyncSpec.self)
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

        @Test("#exhaust async contract with settings")
        func exhaustAsyncContractWithSettings() {
            assertMacro {
                """
                #exhaust(AsyncSpec.self, .commandLimit(10), .concurrent(3))
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
#endif
