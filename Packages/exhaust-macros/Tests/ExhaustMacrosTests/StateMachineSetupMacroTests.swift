#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    // MARK: - @Setup Synthesis

    @Suite(
        "@Setup synthesis tests",
        .macros(testMacros, record: .failed)
    )
    struct SetupSynthesisMacroTests {
        @Test("Setup method synthesizes SetupStep enum, setupGenerator, and runSetup")
        func setupSynthesizesMembers() {
            assertMacro {
                """
                @StateMachine
                final class ConfiguredSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Setup(.int(in: 1 ... 32), .int(in: 0 ... 9).array(length: 0 ... 4))
                    func configure(capacity: Int, preload: [Int]) {
                    }

                    @Command(weight: 1, .int(in: 0 ... 9))
                    func enqueue(value: Int) throws {
                    }
                }
                """
            } expansion: {
                #"""
                final class ConfiguredSpec {
                    var queue: MyQueue!
                    func configure(capacity: Int, preload: [Int]) {
                    }
                    func enqueue(value: Int) throws {
                    }

                    enum Command: CustomStringConvertible, Sendable {
                            case enqueue(value: Int)

                        var description: String {
                            switch self {
                                case let .enqueue(value):
                                "enqueue(\(value))"
                            }
                        }
                    }

                    typealias SystemUnderTest = MyQueue?

                    var systemUnderTest: SystemUnderTest {
                        queue
                    }

                    static var commandGenerator: ReflectiveGenerator<Command> {
                        .oneOf(weighted:
                                (1, #gen((.int(in: 0 ... 9) as ReflectiveGenerator<Int>)) { value in
                                    Command.enqueue(value: value)
                                })
                        )
                    }

                    @discardableResult func run(_ command: Command) throws -> CommandResponse {
                        switch command {
                            case let .enqueue(value):
                                try self.enqueue(value: value)
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() throws {
                    }

                    enum SetupStep: CustomStringConvertible, Sendable {
                        case configure(capacity: Int, preload: [Int])

                        var description: String {
                            switch self {
                                case let .configure(capacity, preload):
                                "configure(capacity: \(capacity), preload: \(preload))"
                            }
                        }
                    }

                    static var setupGenerator: ReflectiveGenerator<SetupStep>? {
                        #gen((.int(in: 1 ... 32) as ReflectiveGenerator<Int>), (.int(in: 0 ... 9).array(length: 0 ... 4) as ReflectiveGenerator<[Int]>)) { capacity, preload in
                            SetupStep.configure(capacity: capacity, preload: preload)
                        }
                    }

                    func runSetup(_ step: SetupStep) throws {
                        switch step {
                            case let .configure(capacity, preload):
                                self.configure(capacity: capacity, preload: preload)
                        }
                    }

                    required init() {
                    }
                }

                extension ConfiguredSpec: StateMachineSpec {
                }
                """#
            }
        }

        @Test("Zero-parameter setup synthesizes a payload-free case and a just generator")
        func zeroParameterSetup() {
            assertMacro {
                """
                @StateMachine
                final class WarmedSpec {
                    @SystemUnderTest var cache: MyCache

                    @Setup
                    func warm() {
                    }

                    @Command(weight: 1)
                    func read() throws {
                    }
                }
                """
            } expansion: {
                """
                final class WarmedSpec {
                    var cache: MyCache
                    func warm() {
                    }
                    func read() throws {
                    }

                    enum Command: CustomStringConvertible, Sendable {
                            case read

                        var description: String {
                            switch self {
                                case .read:
                                "read"
                            }
                        }
                    }

                    typealias SystemUnderTest = MyCache

                    var systemUnderTest: SystemUnderTest {
                        cache
                    }

                    static var commandGenerator: ReflectiveGenerator<Command> {
                        .oneOf(weighted:
                                (1, .just(Command.read))
                        )
                    }

                    @discardableResult func run(_ command: Command) throws -> CommandResponse {
                        switch command {
                            case .read:
                                try self.read()
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() throws {
                    }

                    enum SetupStep: CustomStringConvertible, Sendable {
                        case warm

                        var description: String {
                            switch self {
                                case .warm:
                                "warm"
                            }
                        }
                    }

                    static var setupGenerator: ReflectiveGenerator<SetupStep>? {
                        (.just(SetupStep.warm) as ReflectiveGenerator<SetupStep>)
                    }

                    func runSetup(_ step: SetupStep) throws {
                        switch step {
                            case .warm:
                                self.warm()
                        }
                    }

                    required init() {
                    }
                }

                extension WarmedSpec: StateMachineSpec {
                }
                """
            }
        }

        @Test("An async setup forces the AsyncStateMachineSpec conformance")
        func asyncSetupForcesAsyncConformance() {
            assertMacro {
                """
                @StateMachine
                final class AsyncSetupSpec {
                    @SystemUnderTest var store: MyStore!

                    @Setup(.int(in: 1 ... 4))
                    func open(shards: Int) async throws {
                    }

                    @Command(weight: 1)
                    func read() throws {
                    }
                }
                """
            } expansion: {
                #"""
                final class AsyncSetupSpec {
                    var store: MyStore!
                    func open(shards: Int) async throws {
                    }
                    func read() throws {
                    }

                    enum Command: CustomStringConvertible, Sendable {
                            case read

                        var description: String {
                            switch self {
                                case .read:
                                "read"
                            }
                        }
                    }

                    typealias SystemUnderTest = MyStore?

                    var systemUnderTest: SystemUnderTest {
                        store
                    }

                    static var commandGenerator: ReflectiveGenerator<Command> {
                        .oneOf(weighted:
                                (1, .just(Command.read))
                        )
                    }

                    @discardableResult func run(_ command: Command) async throws -> CommandResponse {
                        switch command {
                            case .read:
                                try self.read()
                                return CommandResponse(commandDescription: command.description, returnValue: nil)
                        }
                    }

                    func checkInvariants() async throws {
                    }

                    enum SetupStep: CustomStringConvertible, Sendable {
                        case open(shards: Int)

                        var description: String {
                            switch self {
                                case let .open(shards):
                                "open(shards: \(shards))"
                            }
                        }
                    }

                    static var setupGenerator: ReflectiveGenerator<SetupStep>? {
                        #gen((.int(in: 1 ... 4) as ReflectiveGenerator<Int>)) { shards in
                            SetupStep.open(shards: shards)
                        }
                    }

                    func runSetup(_ step: SetupStep) async throws {
                        switch step {
                            case let .open(shards):
                                try await self.open(shards: shards)
                        }
                    }

                    required init() {
                    }
                }

                extension AsyncSetupSpec: AsyncStateMachineSpec {
                }
                """#
            }
        }
    }

    // MARK: - @Setup Diagnostics

    @Suite(
        "@Setup diagnostics tests",
        .macros(testMacros, record: .failed)
    )
    struct SetupDiagnosticsMacroTests {
        @Test("A second @Setup method is an error")
        func multipleSetupsDiagnostic() {
            assertMacro {
                """
                @StateMachine
                final class TwoSetupSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Setup(.int(in: 1 ... 32))
                    func configure(capacity: Int) {
                    }

                    @Setup(.int(in: 0 ... 9))
                    func preload(value: Int) {
                    }

                    @Command(weight: 1)
                    func read() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @StateMachine
                final class TwoSetupSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Setup(.int(in: 1 ... 32))
                    func configure(capacity: Int) {
                    }

                    @Setup(.int(in: 0 ... 9))
                    ╰─ 🛑 @StateMachine allows only one @Setup method — merge multi-phase setup into one method whose body runs the phases in order
                    func preload(value: Int) {
                    }

                    @Command(weight: 1)
                    func read() throws {
                    }
                }
                """
            }
        }

        @Test("@Setup combined with @Command on one method is an error")
        func setupCommandConflictDiagnostic() {
            assertMacro {
                """
                @StateMachine
                final class ConflictSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Setup(.int(in: 1 ... 32))
                    @Command(weight: 1, .int(in: 1 ... 32))
                    func configure(capacity: Int) {
                    }

                    @Command(weight: 1)
                    func read() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @StateMachine
                final class ConflictSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Setup(.int(in: 1 ... 32))
                    ╰─ 🛑 @Setup cannot be combined with @Command, @Invariant, or @Equivalence on the same method
                    @Command(weight: 1, .int(in: 1 ... 32))
                    func configure(capacity: Int) {
                    }

                    @Command(weight: 1)
                    func read() throws {
                    }
                }
                """
            }
        }

        @Test("A static @Setup method is an error")
        func staticSetupDiagnostic() {
            assertMacro {
                """
                @StateMachine
                final class StaticSetupSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Setup(.int(in: 1 ... 32))
                    static func configure(capacity: Int) {
                    }

                    @Command(weight: 1)
                    func read() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @StateMachine
                final class StaticSetupSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Setup(.int(in: 1 ... 32))
                    ╰─ 🛑 @Setup must be applied to an instance method — the synthesized dispatch calls it on the spec instance, which Swift rejects for static and class members
                    static func configure(capacity: Int) {
                    }

                    @Command(weight: 1)
                    func read() throws {
                    }
                }
                """
            }
        }

        @Test("A static @Command method is an error")
        func staticCommandDiagnostic() {
            assertMacro {
                """
                @StateMachine
                final class StaticCommandSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Command(weight: 1)
                    static func read() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @StateMachine
                final class StaticCommandSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Command(weight: 1)
                    ╰─ 🛑 @Command must be applied to an instance method — the synthesized dispatch calls it on the spec instance, which Swift rejects for static and class members
                    static func read() throws {
                    }
                }
                """
            }
        }

        @Test("Generator arity mismatch on @Setup is an error")
        func setupArityMismatchDiagnostic() {
            assertMacro {
                """
                @StateMachine
                final class ArityMismatchSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Setup(.int(in: 1 ... 32))
                    func configure(capacity: Int, preload: [Int]) {
                    }

                    @Command(weight: 1)
                    func read() throws {
                    }
                }
                """
            } diagnostics: {
                """
                @StateMachine
                final class ArityMismatchSpec {
                    @SystemUnderTest var queue: MyQueue!

                    @Setup(.int(in: 1 ... 32))
                    ╰─ 🛑 @Setup has 2 parameters but 1 generator — provide exactly one generator per parameter
                    func configure(capacity: Int, preload: [Int]) {
                    }

                    @Command(weight: 1)
                    func read() throws {
                    }
                }
                """
            }
        }
    }

#endif
