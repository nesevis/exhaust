#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    private nonisolated(unsafe) let testMacros: [String: any Macro.Type] = [
        "StateMachine": StateMachineDeclarationMacro.self,
        "SystemUnderTest": SUTMacro.self,
        "Command": CommandMacro.self,
        "Invariant": InvariantMacro.self,
        "Oracle": OracleMacro.self,
    ]

    @Suite(
        "@StateMachine declaration macro tests",
        .macros(testMacros, record: .failed)
    )
    struct StateMachineDeclarationMacroTests {
        @Test("Missing generator expressions produce diagnostic")
        func missingGeneratorExpressionsDiagnostic() {
            assertMacro {
                """
                @StateMachine(.tasks)
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
                @StateMachine(.tasks)
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

        @Test("All-sync commands on final class produce StateMachineSpec conformance")
        func allSyncCommandsProduceStateMachineSpecConformance() {
            assertMacro {
                """
                @StateMachine(.tasks)
                final class SyncSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 1)
                    func increment() throws {
                    }
                }
                """
            } expansion: {
                """
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

                    @discardableResult func run(_ command: Command) throws -> CommandResponse {
                        switch command {
                            case .increment:
                                try self.increment()
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() throws {
                    }

                    static let executionModel: ExecutionModel = .tasks

                    required init() {
                    }
                }

                extension SyncSpec: StateMachineSpec {
                }
                """
            }
        }

        @Test("A public spec mirrors public onto every synthesized member")
        func publicSpecMirrorsAccessLevel() {
            assertMacro {
                """
                @StateMachine(.sequential)
                public final class SharedSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 2, .int(in: 0...9))
                    func add(value: Int) throws {
                    }

                    @Invariant
                    func nonNegative() -> Bool {
                        true
                    }
                }
                """
            } expansion: {
                #"""
                public final class SharedSpec {
                    var counter: MyCounter
                    func add(value: Int) throws {
                    }
                    func nonNegative() -> Bool {
                        true
                    }

                    public enum Command: CustomStringConvertible, Sendable {
                            case add(value: Int)

                        public var description: String {
                            switch self {
                                case let .add(value):
                                "add(\(value))"
                            }
                        }
                    }

                    public typealias SystemUnderTest = MyCounter

                    public var systemUnderTest: SystemUnderTest {
                        counter
                    }

                    public static var commandGenerator: ReflectiveGenerator<Command> {
                        .oneOf(weighted:
                                (2, #gen((.int(in: 0 ... 9) as ReflectiveGenerator<Int>)) { value in
                                    Command.add(value: value)
                                })
                        )
                    }

                    @discardableResult public func run(_ command: Command) throws -> CommandResponse {
                        switch command {
                            case let .add(value):
                                try self.add(value: value)
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    public func checkInvariants() throws {
                            try check(nonNegative(), "nonNegative")
                    }

                    public static let executionModel: ExecutionModel = .sequential

                    public required init() {
                    }
                }

                extension SharedSpec: StateMachineSpec {
                }
                """#
            }
        }

        @Test("An explicit Void return clause normalizes to the nil-response path")
        func explicitVoidReturnNormalizesToNilResponse() {
            assertMacro {
                """
                @StateMachine(.tasks)
                final class VoidReturnSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 1)
                    func increment() throws -> Void {
                    }
                }
                """
            } expansion: {
                """
                final class VoidReturnSpec {
                    var counter: MyCounter
                    func increment() throws -> Void {
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

                    @discardableResult func run(_ command: Command) throws -> CommandResponse {
                        switch command {
                            case .increment:
                                try self.increment()
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() throws {
                    }

                    static let executionModel: ExecutionModel = .tasks

                    required init() {
                    }
                }

                extension VoidReturnSpec: StateMachineSpec {
                }
                """
            }
        }

        @Test("@Command with generator expression produces #gen in commandGenerator")
        func commandWithGeneratorExpressionProducesGenInCommandGenerator() {
            assertMacro {
                """
                @StateMachine(.tasks)
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

                    @discardableResult func run(_ command: Command) throws -> CommandResponse {
                        switch command {
                            case let .insert(value):
                                try self.insert(value: value)
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() throws {
                    }

                    static let executionModel: ExecutionModel = .tasks

                    required init() {
                    }
                }

                extension InsertSpec: StateMachineSpec {
                }
                """#
            }
        }

        @Test("Bare @StateMachine without mode produces diagnostic")
        func bareStateMachineWithoutModeProducesDiagnostic() {
            assertMacro {
                """
                @StateMachine
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @StateMachine
                ┬────────────
                ╰─ 🛑 @StateMachine requires an execution mode: @StateMachine(.sequential|.tasks|.threads)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            }
        }

        @Test("@StateMachine(.tasks) on struct produces diagnostic")
        func specTasksOnStructProducesDiagnostic() {
            assertMacro {
                """
                @StateMachine(.tasks)
                struct Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @StateMachine(.tasks)
                ┬────────────────────
                ╰─ 🛑 State machine specs must be a 'final class' or 'actor' — structs are not supported
                struct Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            }
        }

        @Test("@StateMachine(.threads) on final class with @Oracle produces StateMachineSpec conformance with oracleCheck")
        func specThreadsWithOracleProducesConcurrentConformance() {
            assertMacro {
                """
                @StateMachine(.threads)
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
                """
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

                    @discardableResult func run(_ command: Command) throws -> CommandResponse {
                        switch command {
                            case .increment:
                                try self.increment()
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() throws {
                    }

                    func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                        equivalent(to: sequentialResult)
                    }

                    static let executionModel: ExecutionModel = .threads

                    required init() {
                    }
                }

                extension CounterSpec: StateMachineSpec {
                }
                """
            }
        }

        @Test("@StateMachine(.threads) without @Oracle produces diagnostic")
        func specThreadsWithoutOracleProducesDiagnostic() {
            assertMacro {
                """
                @StateMachine(.threads)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @StateMachine(.threads)
                ┬──────────────────────
                ╰─ 🛑 @StateMachine(.threads) requires exactly one @Oracle method
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            }
        }

        @Test("@StateMachine(.tasks) with @Oracle produces warning")
        func specTasksWithOracleProducesWarning() {
            assertMacro {
                """
                @StateMachine(.tasks)
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
                @StateMachine(.tasks)
                ┬────────────────────
                ╰─ ⚠️ @Oracle is only used with @StateMachine(.threads). For @StateMachine(.sequential) or @StateMachine(.tasks), use @Invariant instead
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
                """
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

                    @discardableResult func run(_ command: Command) throws -> CommandResponse {
                        switch command {
                            case .doSomething:
                                try self.doSomething()
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() throws {
                    }

                    static let executionModel: ExecutionModel = .tasks

                    required init() {
                    }
                }

                extension Spec: StateMachineSpec {
                }
                """
            }
        }

        @Test("@StateMachine(.threads) with @Invariant produces warning")
        func specThreadsWithInvariantProducesWarning() {
            assertMacro {
                """
                @StateMachine(.threads)
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
                @StateMachine(.threads)
                ┬──────────────────────
                ╰─ ⚠️ @Invariant requires deterministic per-step state, which a preemptive run does not have. Use @StateMachine(.tasks)
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
                """
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

                    @discardableResult func run(_ command: Command) throws -> CommandResponse {
                        switch command {
                            case .doSomething:
                                try self.doSomething()
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() throws {
                            try check(valid(), "valid")
                    }

                    func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                        equiv(to: sequentialResult)
                    }

                    static let executionModel: ExecutionModel = .threads

                    required init() {
                    }
                }

                extension Spec: StateMachineSpec {
                }
                """
            }
        }

        @Test("@StateMachine(.threads) on actor produces error")
        func specThreadsOnActorProducesError() {
            assertMacro {
                """
                @StateMachine(.threads)
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
                @StateMachine(.threads)
                ┬──────────────────────
                ╰─ 🛑 Actor specs must use @StateMachine(.sequential). Actors are data-race-free, so .threads cannot surface races in them
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

        @Test("@StateMachine(.tasks) on actor produces error")
        func specTasksOnActorProducesError() {
            assertMacro {
                """
                @StateMachine(.tasks)
                actor Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() async throws {
                    }
                }
                """
            } diagnostics: {
                """
                @StateMachine(.tasks)
                ┬────────────────────
                ╰─ 🛑 Actor specs must use @StateMachine(.sequential). Actor isolation serializes all dispatch, so concurrent testing has nowhere to interleave
                actor Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() async throws {
                    }
                }
                """
            }
        }

        @Test("@StateMachine(.sequential) with @Oracle produces warning")
        func specSequentialWithOracleProducesWarning() {
            assertMacro {
                """
                @StateMachine(.sequential)
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
                @StateMachine(.sequential)
                ┬─────────────────────────
                ╰─ ⚠️ @Oracle is only used with @StateMachine(.threads). For @StateMachine(.sequential) or @StateMachine(.tasks), use @Invariant instead
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
                """
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

                    @discardableResult func run(_ command: Command) throws -> CommandResponse {
                        switch command {
                            case .doSomething:
                                try self.doSomething()
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() throws {
                    }

                    static let executionModel: ExecutionModel = .sequential

                    required init() {
                    }
                }

                extension Spec: StateMachineSpec {
                }
                """
            }
        }

        @Test("@StateMachine(.sequential) on actor synthesizes diagnosticSnapshot and init")
        func specSequentialOnActorSynthesizesDiagnosticSnapshot() {
            assertMacro {
                """
                @StateMachine(.sequential)
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
                """
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

                    @discardableResult func run(_ command: Command) async throws -> CommandResponse {
                        switch command {
                            case .doSomething:
                                try await self.doSomething()
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() async throws {
                            let valueMatchesResult = await valueMatches()
                            try check(valueMatchesResult, "valueMatches")
                    }

                    static let executionModel: ExecutionModel = .sequential

                    func diagnosticSnapshot() async -> DiagnosticSnapshot<SystemUnderTest> {
                        DiagnosticSnapshot(systemUnderTest: systemUnderTest, failureDescription: failureDescription())
                    }

                    init() {
                    }
                }

                extension Spec: @preconcurrency AsyncStateMachineSpec {
                }
                """
            }
        }
    }

    @Suite(
        "@StateMachine tab indentation tests",
        .macros(testMacros, indentationWidth: .tabs(1), record: .failed)
    )
    struct StateMachineTabIndentationTests {
        @Test("@StateMachine(.tasks) with tab indentation and generator expressions")
        func specWithTabIndentationAndGeneratorExpressions() {
            assertMacro {
                """
                @StateMachine(.tasks)
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

                	@discardableResult func run(_ command: Command) throws -> CommandResponse {
                	    switch command {
                	        case let .insert(value):
                	            try self.insert(value: value)
                	            return CommandResponse(commandDescription: command.description, returnValue: nil)
                	    }
                	}

                	func checkInvariants() throws {
                	}

                	static let executionModel: ExecutionModel = .tasks

                	required init() {
                	}
                }

                extension InsertSpec: StateMachineSpec {
                }
                """#
            }
        }

        @Test("@StateMachine(.tasks) with tab indentation and non-model properties")
        func specWithTabIndentationAndNonModelProperties() {
            assertMacro {
                """
                @StateMachine(.tasks)
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
                """
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

                	@discardableResult func run(_ command: Command) throws -> CommandResponse {
                	    switch command {
                	        case .doSomething:
                	            try self.doSomething()
                	            return CommandResponse(commandDescription: command.description, returnValue: nil)
                	    }
                	}

                	func checkInvariants() throws {
                	}

                	static let executionModel: ExecutionModel = .tasks

                	required init() {
                	}
                }

                extension Spec: StateMachineSpec {
                }
                """
            }
        }

        @Test("Duplicate @Command base names produce diagnostic")
        func duplicateCommandBaseNamesProduceDiagnostic() {
            assertMacro {
                """
                @StateMachine(.tasks)
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
                @StateMachine(.tasks)
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
                @StateMachine(.tasks)
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
                @StateMachine(.tasks)
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
                @StateMachine(.threads)
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
                @StateMachine(.threads)
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

        @Test("@StateMachine(.typo) produces nonLiteralMode, not missingMode")
        func specWithTypoProducesNonLiteralMode() {
            assertMacro {
                """
                @StateMachine(.task)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command(weight: 1)
                    func action() throws {
                    }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @StateMachine(.task)
                ┬───────────────────
                ╰─ 🛑 The execution mode must be a literal ExecutionModel case (.sequential|.tasks|.threads)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command(weight: 1)
                    func action() throws {
                    }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            }
        }

        @Test("Variadic @Command parameter produces diagnostic")
        func variadicCommandParameterProducesDiagnostic() {
            assertMacro {
                """
                @StateMachine(.tasks)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command(weight: 1, .int(in: 0...9))
                    func add(_ values: Int...) throws {
                    }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @StateMachine(.tasks)
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command(weight: 1, .int(in: 0...9))
                    ╰─ 🛑 @Command parameters must not be inout, variadic, or generic — the synthesized Command enum cannot represent them
                    func add(_ values: Int...) throws {
                    }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            }
        }

        @Test("Multi-binding @SystemUnderTest triggers multipleSUT")
        func multiBindingSUTTriggersMultipleSUT() {
            assertMacro {
                """
                @StateMachine(.tasks)
                final class Spec {
                    @SystemUnderTest var a: MySUT, b: MySUT

                    @Command(weight: 1)
                    func action() throws {
                    }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @StateMachine(.tasks)
                ┬────────────────────
                ╰─ 🛑 @StateMachine requires exactly one @SystemUnderTest property, but multiple were found
                final class Spec {
                    @SystemUnderTest var a: MySUT, b: MySUT
                    ┬───────────────
                    ╰─ 🛑 peer macro can only be applied to a single variable

                    @Command(weight: 1)
                    func action() throws {
                    }

                    @Invariant
                    func valid() -> Bool { true }
                }
                """
            }
        }
    }

    // MARK: - Marker Macro Attachment Validation

    @Suite("Marker macro attachment validation", .macros(testMacros, record: .failed))
    struct MarkerMacroAttachmentTests {
        @Test("@SystemUnderTest on a method produces diagnostic")
        func sutOnMethod() {
            assertMacro {
                """
                @SystemUnderTest
                func notAProperty() {}
                """
            } diagnostics: {
                """
                @SystemUnderTest
                ┬───────────────
                ╰─ 🛑 @SystemUnderTest must be applied to a stored property
                func notAProperty() {}
                """
            }
        }

        @Test("@Command on a property produces diagnostic")
        func commandOnProperty() {
            assertMacro {
                """
                @Command(weight: 1)
                var notAMethod: Int = 0
                """
            } diagnostics: {
                """
                @Command(weight: 1)
                ┬──────────────────
                ╰─ 🛑 @Command must be applied to a method
                var notAMethod: Int = 0
                """
            }
        }

        @Test("@Invariant on a property produces diagnostic")
        func invariantOnProperty() {
            assertMacro {
                """
                @Invariant
                var notAMethod: Bool = true
                """
            } diagnostics: {
                """
                @Invariant
                ┬─────────
                ╰─ 🛑 @Invariant must be applied to a method
                var notAMethod: Bool = true
                """
            }
        }

        @Test("@Oracle on a property produces diagnostic")
        func oracleOnProperty() {
            assertMacro {
                """
                @Oracle
                var notAMethod: Bool = true
                """
            } diagnostics: {
                """
                @Oracle
                ┬──────
                ╰─ 🛑 @Oracle must be applied to a method
                var notAMethod: Bool = true
                """
            }
        }

        @Test("@SystemUnderTest on a property produces no diagnostic")
        func sutOnProperty() {
            assertMacro {
                """
                @SystemUnderTest
                var sut: MyType = .init()
                """
            } expansion: {
                """
                var sut: MyType = .init()
                """
            }
        }

        @Test("@Command on a method produces no diagnostic")
        func commandOnMethod() {
            assertMacro {
                """
                @Command(weight: 1)
                func doSomething() {}
                """
            } expansion: {
                """
                func doSomething() {}
                """
            }
        }

        @Test("@Invariant on a method produces no diagnostic")
        func invariantOnMethod() {
            assertMacro {
                """
                @Invariant
                func isValid() -> Bool { true }
                """
            } expansion: {
                """
                func isValid() -> Bool { true }
                """
            }
        }

        @Test("@Oracle on a method produces no diagnostic")
        func oracleOnMethod() {
            assertMacro {
                """
                @Oracle
                func matches(other: MyType) -> Bool { true }
                """
            } expansion: {
                """
                func matches(other: MyType) -> Bool { true }
                """
            }
        }
    }

#endif
