#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "@StateMachine declaration macro tests",
        .macros(testMacros, record: .failed)
    )
    struct StateMachineDeclarationMacroTests {
        @Test("Missing generator expressions produce diagnostic")
        func missingGeneratorExpressionsDiagnostic() {
            assertMacro {
                """
                @StateMachine
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
                @StateMachine
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
                @StateMachine
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
                @StateMachine
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
                @StateMachine
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
                @StateMachine
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

                    required init() {
                    }
                }

                extension InsertSpec: StateMachineSpec {
                }
                """#
            }
        }

        @Test("@StateMachine on struct produces diagnostic")
        func specTasksOnStructProducesDiagnostic() {
            assertMacro {
                """
                @StateMachine
                struct Spec {
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
                ╰─ 🛑 State machine specs must be a 'final class' — structs are not supported
                struct Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() throws {
                    }
                }
                """
            }
        }

        @Test("@StateMachine on final class with @Equivalence produces StateMachineSpec conformance with equivalenceCheck")
        func specThreadsWithOracleProducesConcurrentConformance() {
            assertMacro {
                """
                @StateMachine
                final class CounterSpec {
                    @SystemUnderTest var counter: MyCounter

                    @Command(weight: 3)
                    func increment() throws {
                    }

                    @Equivalence
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

                    func equivalenceCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                        equivalent(to: sequentialResult)
                    }

                    static let hasEquivalence: Bool = true

                    required init() {
                    }
                }

                extension CounterSpec: StateMachineSpec {
                }
                """
            }
        }

        @Test("@StateMachine on actor produces diagnostic")
        func specOnActorProducesDiagnostic() {
            assertMacro {
                """
                @StateMachine
                actor Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() async throws {
                    }
                }
                """
            } diagnostics: {
                """
                @StateMachine
                ┬────────────
                ╰─ 🛑 State machine specs must be a 'final class' — actor isolation serializes every command, so no mode can interleave them. To test an actor, make it the @SystemUnderTest of a final class spec.
                actor Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command
                    func doSomething() async throws {
                    }
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
        @Test("@StateMachine with tab indentation and generator expressions")
        func specWithTabIndentationAndGeneratorExpressions() {
            assertMacro {
                """
                @StateMachine
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

                	required init() {
                	}
                }

                extension InsertSpec: StateMachineSpec {
                }
                """#
            }
        }

        @Test("@StateMachine with tab indentation and non-model properties")
        func specWithTabIndentationAndNonModelProperties() {
            assertMacro {
                """
                @StateMachine
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
                @StateMachine
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
                @StateMachine
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
                @StateMachine
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
                @StateMachine
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

        @Test("Parameterless @Equivalence names the parameter requirement rather than going unreported")
        func parameterlessEquivalenceProducesTargetedDiagnostic() {
            assertMacro {
                """
                @StateMachine
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command(weight: 1)
                    func action() throws {
                    }

                    @Equivalence
                    func isConsistent() -> Bool { true }
                }
                """
            } diagnostics: {
                """
                @StateMachine
                final class Spec {
                    @SystemUnderTest var sut: MySUT

                    @Command(weight: 1)
                    func action() throws {
                    }

                    @Equivalence
                    ╰─ 🛑 @Equivalence must take exactly one parameter of the SystemUnderTest type
                    func isConsistent() -> Bool { true }
                }
                """
            }
        }

        @Test("Variadic @Command parameter produces diagnostic")
        func variadicCommandParameterProducesDiagnostic() {
            assertMacro {
                """
                @StateMachine
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
                @StateMachine
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
                @StateMachine
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
                @StateMachine
                ┬────────────
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

        @Test("@Setup on an initializer produces diagnostic")
        func setupOnInitializer() {
            assertMacro {
                """
                @Setup(.int(in: 1 ... 8))
                init(capacity: Int) {}
                """
            } diagnostics: {
                """
                @Setup(.int(in: 1 ... 8))
                ┬────────────────────────
                ╰─ 🛑 @Setup must be applied to a method
                init(capacity: Int) {}
                """
            }
        }

        @Test("@Setup on a property produces diagnostic")
        func setupOnProperty() {
            assertMacro {
                """
                @Setup
                var notAMethod: Int = 0
                """
            } diagnostics: {
                """
                @Setup
                ┬─────
                ╰─ 🛑 @Setup must be applied to a method
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

        @Test("@Equivalence on a property produces diagnostic")
        func oracleOnProperty() {
            assertMacro {
                """
                @Equivalence
                var notAMethod: Bool = true
                """
            } diagnostics: {
                """
                @Equivalence
                ┬───────────
                ╰─ 🛑 @Equivalence must be applied to a method
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

        @Test("@Equivalence on a method produces no diagnostic")
        func oracleOnMethod() {
            assertMacro {
                """
                @Equivalence
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
