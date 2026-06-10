#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    private nonisolated(unsafe) let testMacros: [String: any Macro.Type] = [
        "Contract": ContractDeclarationMacro.self,
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
                    var contents: [Int] = []
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
                    var contents: [Int] = []
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

                    func failureDescription() -> String {
                        "\(counter)"
                    }

                    static let executionModel: ExecutionModel = .tasks

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

                    func failureDescription() -> String {
                        "\(items)"
                    }

                    static let executionModel: ExecutionModel = .tasks

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
                ╰─ 🛑 @Contract requires an execution mode: @Contract(.sequential|.tasks|.threads)
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

                    func failureDescription() -> String {
                        "\(counter)"
                    }

                    func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                        equivalent(to: sequentialResult)
                    }

                    static let executionModel: ExecutionModel = .threads

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
                ╰─ ⚠️ @Oracle is only used with @Contract(.threads). For @Contract(.sequential) or @Contract(.tasks), use @Invariant instead
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

                    func failureDescription() -> String {
                        "\(sut)"
                    }

                    static let executionModel: ExecutionModel = .tasks

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

                    func failureDescription() -> String {
                        "\(sut)"
                    }

                    func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                        equiv(to: sequentialResult)
                    }

                    static let executionModel: ExecutionModel = .threads

                    required init() {
                    }
                }

                extension Spec: ContractSpec {
                }
                """#
            }
        }

        @Test("@Contract(.threads) on actor produces error")
        func contractThreadsOnActorProducesError() {
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
                ╰─ 🛑 Actor contracts must use @Contract(.sequential). Actors are data-race-free, so .threads cannot surface races in them
                actor Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }

                    @Oracle
                    func equiv(to other: MySUT) -> Bool { true }
                }
                """
            }
        }

        @Test("@Contract(.tasks) on actor produces error")
        func contractTasksOnActorProducesError() {
            assertMacro {
                """
                @Contract(.tasks)
                actor Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() async throws {
                    }
                }
                """
            } diagnostics: {
                """
                @Contract(.tasks)
                ┬────────────────
                ╰─ 🛑 Actor contracts must use @Contract(.sequential). Actor isolation serialises all dispatch, so concurrent testing has nowhere to interleave
                actor Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() async throws {
                    }
                }
                """
            }
        }

        @Test("@Contract(.sequential) with @Oracle produces warning")
        func contractSequentialWithOracleProducesWarning() {
            assertMacro {
                """
                @Contract(.sequential)
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
                @Contract(.sequential)
                ┬─────────────────────
                ╰─ ⚠️ @Oracle is only used with @Contract(.threads). For @Contract(.sequential) or @Contract(.tasks), use @Invariant instead
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

                    func failureDescription() -> String {
                        "\(sut)"
                    }

                    static let executionModel: ExecutionModel = .sequential

                    required init() {
                    }
                }

                extension Spec: ContractSpec {
                }
                """#
            }
        }

        @Test("@Contract(.sequential) on actor synthesizes diagnosticSnapshot and init")
        func contractSequentialOnActorSynthesizesDiagnosticSnapshot() {
            assertMacro {
                """
                @Contract(.sequential)
                actor Spec {
                    var expected: Int = 0
                    @SystemUnderTest var sut: MySUT

                    @Invariant
                    func valueMatches() async -> Bool {
                        true
                    }

                    @Command
                    func doSomething() async throws {
                    }
                }
                """
            } expansion: {
                #"""
                actor Spec {
                    var expected: Int = 0
                    var sut: MySUT
                    func valueMatches() async -> Bool {
                        true
                    }
                    func doSomething() async throws {
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

                    func run(_ command: Command) async throws {
                        switch command {
                            case .doSomething:
                            try await self.doSomething()
                        }
                    }

                    func checkInvariants() async throws {
                            let valueMatchesResult = await valueMatches()
                            try check(valueMatchesResult, "valueMatches")
                    }

                    func failureDescription() -> String {
                        "\(sut)"
                    }

                    static let executionModel: ExecutionModel = .sequential

                    func diagnosticSnapshot() async -> DiagnosticSnapshot<SystemUnderTest> {
                        DiagnosticSnapshot(systemUnderTest: systemUnderTest, failureDescription: failureDescription())
                    }

                    init() {
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

                	func failureDescription() -> String {
                		"\(items)"
                	}

                	static let executionModel: ExecutionModel = .tasks

                	required init() {
                	}
                }

                extension InsertSpec: ContractSpec {
                }
                """#
            }
        }

        @Test("@Contract(.tasks) with tab indentation and non-model properties")
        func contractWithTabIndentationAndNonModelProperties() {
            assertMacro {
                """
                @Contract(.tasks)
                final class Spec {
                \tvar count: Int = 0
                \tvar name: String = ""
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

                	func failureDescription() -> String {
                		"\(sut)"
                	}

                	static let executionModel: ExecutionModel = .tasks

                	required init() {
                	}
                }

                extension Spec: ContractSpec {
                }
                """#
            }
        }

        @Test("Duplicate @Command base names produce diagnostic")
        func duplicateCommandBaseNamesProduceDiagnostic() {
            assertMacro {
                """
                @Contract(.tasks)
                final class QueueSpec {
                    @SystemUnderTest var queue: MyQueue

                    @Command(weight: 1)
                    func push() throws {
                    }

                    @Command(weight: 1)
                    func push() throws {
                    }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @Contract(.tasks)
                final class QueueSpec {
                    @SystemUnderTest var queue: MyQueue

                    @Command(weight: 1)
                    func push() throws {
                    }

                    @Command(weight: 1)
                    ╰─ 🛑 Two @Command methods share the same base name — rename one or merge them
                    func push() throws {
                    }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            }
        }

        @Test("Zero @Command weight produces diagnostic")
        func zeroCommandWeightProducesDiagnostic() {
            assertMacro {
                """
                @Contract(.tasks)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command(weight: 0)
                    func action() throws {
                    }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @Contract(.tasks)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command(weight: 0)
                    ╰─ 🛑 @Command weight must be a positive integer literal
                    func action() throws {
                    }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            }
        }

        @Test("Parameterless @Oracle produces targeted diagnostic instead of noOracle")
        func parameterlessOracleProducesTargetedDiagnostic() {
            assertMacro {
                """
                @Contract(.threads)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command(weight: 1)
                    func action() throws {
                    }

                    @Oracle
                    func isConsistent() -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @Contract(.threads)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command(weight: 1)
                    func action() throws {
                    }

                    @Oracle
                    ╰─ 🛑 @Oracle must take exactly one parameter of the SystemUnderTest type
                    func isConsistent() -> Bool { true }
                }
                """
            }
        }
    }

#endif
