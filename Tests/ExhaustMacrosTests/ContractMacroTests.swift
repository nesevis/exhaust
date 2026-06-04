#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    private nonisolated(unsafe) let testMacros: [String: any Macro.Type] = [
        "Contract": ContractDeclarationMacro.self,
        "Model": ModelMacro.self,
        "SystemUnderTest": SUTMacro.self,
        "Command": CommandMacro.self,
        "Invariant": InvariantMacro.self,
        "Oracle": OracleMacro.self,
    ]

    @Suite(
        "@Contract declaration macro tests",
        .macros(testMacros, record: .failed)
    )
    struct ContractDeclarationMacroTests {
        @Test("Missing generator expressions produce diagnostic")
        func missingGeneratorExpressionsDiagnostic() {
            assertMacro {
                """
                @Contract(.tasks)
                final class QueueSpec {
                    @Model var contents: [Int] = []
                    @SystemUnderTest var queue: MyQueue

                    @Command(weight: 3)
                    func enqueue(value: Int) throws {
                    }

                    @Command(weight: 2)
                    func dequeue() throws {
                    }

                    @Invariant
                    func countMatches() -> Bool {
                        true
                    }
                }
                """
            } diagnostics: {
                """
                @Contract(.tasks)
                final class QueueSpec {
                    @Model var contents: [Int] = []
                    @SystemUnderTest var queue: MyQueue

                    @Command(weight: 3)
                    ╰─ 🛑 @Command method has parameters but no generator expressions — add generators to the @Command attribute
                    func enqueue(value: Int) throws {
                    }

                    @Command(weight: 2)
                    func dequeue() throws {
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

        @Test("All-sync commands on final class produce ContractSpec conformance")
        func allSyncCommandsProduceContractSpecConformance() {
            assertMacro {
                """
                @Contract(.tasks)
                final class SyncSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 1)
                    func increment() throws {
                    }
                }
                """
            } expansion: {
                #"""
                final class SyncSpec {
                    var counter: MyCounter
                    func increment() throws {
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

                    func run(_ command: Command) throws {
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

                    static let concurrencyModel: ExecutionModel = .tasks

                    required init() {
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
                @Contract(.tasks)
                final class InsertSpec {
                    @SystemUnderTest var items: [Int]

                    @Command(weight: 3, .int(in: 0...99))
                    func insert(value: Int) throws {
                    }
                }
                """
            } expansion: {
                #"""
                final class InsertSpec {
                    var items: [Int]
                    func insert(value: Int) throws {
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

                    func run(_ command: Command) throws {
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

                    static let concurrencyModel: ExecutionModel = .tasks

                    required init() {
                    }
                }

                extension InsertSpec: ContractSpec {
                }
                """#
            }
        }

        @Test("Bare @Contract without mode produces diagnostic")
        func bareContractWithoutModeProducesDiagnostic() {
            assertMacro {
                """
                @Contract
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @Contract
                ┬────────
                ├─ 🛑 @Contract requires a concurrency mode argument: @Contract(.tasks) or @Contract(.threads)
                ╰─ 🛑 @Contract requires a concurrency mode argument: @Contract(.tasks) or @Contract(.threads)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            }
        }

        @Test("@Contract(.tasks) on struct produces diagnostic")
        func contractTasksOnStructProducesDiagnostic() {
            assertMacro {
                """
                @Contract(.tasks)
                struct Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @Contract(.tasks)
                ┬────────────────
                ├─ 🛑 Contract specs must be a 'final class' or 'actor' — structs are not supported
                ╰─ 🛑 Contract specs must be a 'final class' or 'actor' — structs are not supported
                struct Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            }
        }

        @Test("@Contract(.threads) on final class with @Oracle produces ContractSpec conformance with oracleCheck")
        func contractThreadsWithOracleProducesConcurrentConformance() {
            assertMacro {
                """
                @Contract(.threads)
                final class CounterSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 3)
                    func increment() throws {
                    }

                    @Oracle
                    func equivalent(to other: MyCounter) -> Bool {
                        counter.value == other.value
                    }
                }
                """
            } expansion: {
                #"""
                final class CounterSpec {
                    var counter: MyCounter
                    func increment() throws {
                    }
                    func equivalent(to other: MyCounter) -> Bool {
                        counter.value == other.value
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
                                (3, .just(Command.increment))
                        )
                    }

                    func run(_ command: Command) throws {
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

                    func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                        equivalent(to: sequentialResult)
                    }

                    static let concurrencyModel: ExecutionModel = .threads

                    required init() {
                    }
                }

                extension CounterSpec: ContractSpec {
                }
                """#
            }
        }

        @Test("@Contract(.threads) without @Oracle produces diagnostic")
        func contractThreadsWithoutOracleProducesDiagnostic() {
            assertMacro {
                """
                @Contract(.threads)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @Contract(.threads)
                ┬──────────────────
                ╰─ 🛑 @Contract(.threads) requires exactly one @Oracle method
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            }
        }

        @Test("@Contract(.tasks) with @Oracle produces warning")
        func contractTasksWithOracleProducesWarning() {
            assertMacro {
                """
                @Contract(.tasks)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }

                    @Oracle
                    func equiv(to other: MySUT) -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @Contract(.tasks)
                ┬────────────────
                ╰─ ⚠️ @Oracle is only used with @Contract(.threads). For @Contract(.tasks), use @Invariant and @Model instead
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }

                    @Oracle
                    func equiv(to other: MySUT) -> Bool { true }
                }
                """
            } expansion: {
                #"""
                final class Spec {
                    var sut: MySUT
                    func doSomething() throws {
                    }
                    func equiv(to other: MySUT) -> Bool { true }

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

                    func run(_ command: Command) throws {
                        switch command {
                            case .doSomething:
                            try self.doSomething()
                        }
                    }

                    func checkInvariants() throws {
                    }

                    var modelDescription: String {
                        "(no model properties)"
                    }

                    var sutDescription: String {
                        "sut: \(sut)"
                    }

                    static let concurrencyModel: ExecutionModel = .tasks

                    required init() {
                    }
                }

                extension Spec: ContractSpec {
                }
                """#
            }
        }

        @Test("@Contract(.threads) with @Invariant produces warning")
        func contractThreadsWithInvariantProducesWarning() {
            assertMacro {
                """
                @Contract(.threads)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }

                    @Oracle
                    func equiv(to other: MySUT) -> Bool { true }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @Contract(.threads)
                ┬──────────────────
                ╰─ ⚠️ @Invariant requires deterministic per-step state, which a preemptive run does not have. Use @Contract(.tasks)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }

                    @Oracle
                    func equiv(to other: MySUT) -> Bool { true }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            } expansion: {
                #"""
                final class Spec {
                    var sut: MySUT
                    func doSomething() throws {
                    }
                    func equiv(to other: MySUT) -> Bool { true }
                    func valid() -> Bool { true }

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

                    func run(_ command: Command) throws {
                        switch command {
                            case .doSomething:
                            try self.doSomething()
                        }
                    }

                    func checkInvariants() throws {
                            try check(valid(), "valid")
                    }

                    var modelDescription: String {
                        "(no model properties)"
                    }

                    var sutDescription: String {
                        "sut: \(sut)"
                    }

                    func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                        equiv(to: sequentialResult)
                    }

                    static let concurrencyModel: ExecutionModel = .threads

                    required init() {
                    }
                }

                extension Spec: ContractSpec {
                }
                """#
            }
        }

        @Test("@Contract(.threads) with @Model produces warning")
        func contractThreadsWithModelProducesWarning() {
            assertMacro {
                """
                @Contract(.threads)
                final class Spec {
                    @Model var count: Int = 0
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }

                    @Oracle
                    func equiv(to other: MySUT) -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @Contract(.threads)
                ┬──────────────────
                ╰─ ⚠️ @Model requires deterministic per-step state, which a preemptive run does not have. Use @Contract(.tasks)
                final class Spec {
                    @Model var count: Int = 0
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }

                    @Oracle
                    func equiv(to other: MySUT) -> Bool { true }
                }
                """
            } expansion: {
                #"""
                final class Spec {
                    var count: Int = 0
                    var sut: MySUT
                    func doSomething() throws {
                    }
                    func equiv(to other: MySUT) -> Bool { true }

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

                    func run(_ command: Command) throws {
                        switch command {
                            case .doSomething:
                            try self.doSomething()
                        }
                    }

                    func checkInvariants() throws {
                    }

                    var modelDescription: String {
                        "count: \(count)"
                    }

                    var sutDescription: String {
                        "sut: \(sut)"
                    }

                    func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                        equiv(to: sequentialResult)
                    }

                    static let concurrencyModel: ExecutionModel = .threads

                    required init() {
                    }
                }

                extension Spec: ContractSpec {
                }
                """#
            }
        }

        @Test("@Contract(.threads) on actor produces warning")
        func contractThreadsOnActorProducesWarning() {
            assertMacro {
                """
                @Contract(.threads)
                actor Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }

                    @Oracle
                    func equiv(to other: MySUT) -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @Contract(.threads)
                ┬──────────────────
                ╰─ ⚠️ Actors are data-race-free; .threads cannot surface races in them. Use @Contract(.tasks)
                actor Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }

                    @Oracle
                    func equiv(to other: MySUT) -> Bool { true }
                }
                """
            } expansion: {
                #"""
                actor Spec {
                    var sut: MySUT
                    func doSomething() throws {
                    }
                    func equiv(to other: MySUT) -> Bool { true }

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

                    func run(_ command: Command) async throws {
                        switch command {
                            case .doSomething:
                            try self.doSomething()
                        }
                    }

                    func checkInvariants() async throws {
                    }

                    var modelDescription: String {
                        "(no model properties)"
                    }

                    var sutDescription: String {
                        "sut: \(sut)"
                    }

                    func oracleCheck(_ sequentialResult: SystemUnderTest) async -> Bool {
                        equiv(to: sequentialResult)
                    }

                    static let concurrencyModel: ExecutionModel = .threads

                    nonisolated init() {
                    }
                }

                extension Spec: @preconcurrency AsyncContractSpec {
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
        @Test("@Contract(.tasks) with tab indentation and generator expressions")
        func contractWithTabIndentationAndGeneratorExpressions() {
            assertMacro {
                """
                @Contract(.tasks)
                final class InsertSpec {
                \t@SystemUnderTest var items: [Int]

                \t@Command(weight: 3, .int(in: 0...99))
                \tfunc insert(value: Int) throws {
                \t}
                }
                """
            } expansion: {
                #"""
                final class InsertSpec {
                	var items: [Int]
                	func insert(value: Int) throws {
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

                	func run(_ command: Command) throws {
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

                	static let concurrencyModel: ExecutionModel = .tasks

                	required init() {
                	}
                }

                extension InsertSpec: ContractSpec {
                }
                """#
            }
        }

        @Test("@Contract(.tasks) with tab indentation and multiple model properties")
        func contractWithTabIndentationAndMultipleModelProperties() {
            assertMacro {
                """
                @Contract(.tasks)
                final class Spec {
                \t@Model var count: Int = 0
                \t@Model var name: String = ""
                \t@SystemUnderTest var sut: MySUT

                \t@Command(weight: 1)
                \tfunc doSomething() throws {
                \t}
                }
                """
            } expansion: {
                #"""
                final class Spec {
                	var count: Int = 0
                	var name: String = ""
                	var sut: MySUT
                	func doSomething() throws {
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

                	func run(_ command: Command) throws {
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

                	static let concurrencyModel: ExecutionModel = .tasks

                	required init() {
                	}
                }

                extension Spec: ContractSpec {
                }
                """#
            }
        }
    }

#endif
