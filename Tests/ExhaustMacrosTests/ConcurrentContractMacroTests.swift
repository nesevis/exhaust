import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import ExhaustMacros

private let concurrentMacros: [String: any Macro.Type] = [
    "ConcurrentContract": ConcurrentContractDeclarationMacro.self,
    "Model": ModelMacro.self,
    "SystemUnderTest": SUTMacro.self,
    "Command": CommandMacro.self,
    "Invariant": InvariantMacro.self,
    "Oracle": OracleMacro.self,
]

@Suite("@ConcurrentContract declaration macro tests")
struct ConcurrentContractMacroTests {
    @Test("Synthesizes Command enum, SUT typealias, oracleCheck, and ConcurrentContractSpec conformance")
    func synthesizesFullSpec() {
        assertMacroExpansion(
            """
            @ConcurrentContract
            final class CounterSpec {
                @Model var expected: Int = 0
                @SystemUnderTest var counter: MyCounter

                @Oracle
                func valuesMatch(other: MyCounter) -> Bool {
                    counter.value == other.value
                }

                @Command(weight: 3)
                func increment() throws {
                }

                @Command(weight: 2)
                func read() throws {
                }

                @Invariant
                func isNonNegative() -> Bool {
                    true
                }
            }
            """,
            expandedSource: """
            final class CounterSpec {
                var expected: Int = 0
                var counter: MyCounter

                func valuesMatch(other: MyCounter) -> Bool {
                    counter.value == other.value
                }

                func increment() throws {
                }

                func read() throws {
                }

                func isNonNegative() -> Bool {
                    true
                }

                enum Command: CustomStringConvertible, Sendable {
                    case increment
                    case read

                    var description: String {
                        switch self {
                            case .increment: "increment"
                            case .read: "read"
                        }
                    }
                }

                typealias SystemUnderTest = MyCounter

                var systemUnderTest: SystemUnderTest {
                    counter
                }

                static var commandGenerator: ReflectiveGenerator<Command> {
                    .oneOf(weighted:
                        (3, .just(Command.increment)),
                        (2, .just(Command.read))
                    )
                }

                func run(_ command: Command) throws {
                    switch command {
                        case .increment: try self.increment()
                        case .read: try self.read()
                    }
                }

                func checkInvariants() throws {
                    try check(isNonNegative(), "isNonNegative")
                }

                var modelDescription: String {
                    "expected: \\(expected)"
                }

                var sutDescription: String {
                    "counter: \\(counter)"
                }

                func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                    valuesMatch(other: sequentialResult)
                }

                required init() {
                }
            }

            extension CounterSpec: ConcurrentContractSpec {
            }
            """,
            macros: concurrentMacros
        )
    }

    @Test("Async commands produce AsyncConcurrentContractSpec conformance")
    func asyncCommandsSynthesizeAsyncConformance() {
        assertMacroExpansion(
            """
            @ConcurrentContract
            final class AsyncCounterSpec {
                @SystemUnderTest var counter: MyCounter

                @Oracle
                func valuesMatch(other: MyCounter) -> Bool {
                    true
                }

                @Command(weight: 1)
                func increment() async throws {
                }
            }
            """,
            expandedSource: """
            final class AsyncCounterSpec {
                var counter: MyCounter

                func valuesMatch(other: MyCounter) -> Bool {
                    true
                }

                func increment() async throws {
                }

                enum Command: CustomStringConvertible, Sendable {
                    case increment

                    var description: String {
                        switch self {
                            case .increment: "increment"
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

                func run(_ command: Command) async throws {
                    switch command {
                        case .increment: try await self.increment()
                    }
                }

                func checkInvariants() async throws {
                }

                var modelDescription: String {
                    "(no model properties)"
                }

                var sutDescription: String {
                    "counter: \\(counter)"
                }

                func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                    valuesMatch(other: sequentialResult)
                }

                required init() {
                }
            }

            extension AsyncCounterSpec: AsyncConcurrentContractSpec {
            }
            """,
            macros: concurrentMacros
        )
    }

    @Test("Missing @Oracle produces diagnostic")
    func missingOracleProducesDiagnostic() {
        assertMacroExpansion(
            """
            @ConcurrentContract
            final class NoOracleSpec {
                @SystemUnderTest var counter: MyCounter

                @Command(weight: 1)
                func increment() throws {
                }
            }
            """,
            expandedSource: """
            final class NoOracleSpec {
                var counter: MyCounter

                func increment() throws {
                }

                enum Command: CustomStringConvertible, Sendable {
                    case increment

                    var description: String {
                        switch self {
                            case .increment: "increment"
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
                        case .increment: try self.increment()
                    }
                }

                func checkInvariants() throws {
                }

                var modelDescription: String {
                    "(no model properties)"
                }

                var sutDescription: String {
                    "counter: \\(counter)"
                }

                required init() {
                }
            }

            extension NoOracleSpec: ConcurrentContractSpec {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: ConcurrentContractDiagnostic.noOracle.rawValue, line: 1, column: 1),
            ],
            macros: concurrentMacros
        )
    }

    @Test("Struct (not class) produces diagnostic")
    func structProducesDiagnostic() {
        assertMacroExpansion(
            """
            @ConcurrentContract
            struct NotAClassSpec {
                @SystemUnderTest var counter: MyCounter

                @Oracle
                func valuesMatch(other: MyCounter) -> Bool { true }

                @Command(weight: 1)
                mutating func increment() throws {
                }
            }
            """,
            expandedSource: """
            struct NotAClassSpec {
                var counter: MyCounter

                func valuesMatch(other: MyCounter) -> Bool { true }

                mutating func increment() throws {
                }

                enum Command: CustomStringConvertible, Sendable {
                    case increment

                    var description: String {
                        switch self {
                            case .increment: "increment"
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
                        case .increment: try self.increment()
                    }
                }

                func checkInvariants() throws {
                }

                var modelDescription: String {
                    "(no model properties)"
                }

                var sutDescription: String {
                    "counter: \\(counter)"
                }

                func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                    valuesMatch(other: sequentialResult)
                }
            }

            extension NotAClassSpec: ConcurrentContractSpec {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: ConcurrentContractDiagnostic.mustBeClass.rawValue, line: 1, column: 1),
            ],
            macros: concurrentMacros
        )
    }

    @Test("@Oracle marker macro produces no peer declarations")
    func oracleMarkerIsEmpty() {
        assertMacroExpansion(
            """
            @Oracle
            func check(other: MyCounter) -> Bool { true }
            """,
            expandedSource: """
            func check(other: MyCounter) -> Bool { true }
            """,
            macros: concurrentMacros
        )
    }

    @Test("@Command with generator expression synthesizes correctly")
    func commandWithGenerator() {
        assertMacroExpansion(
            """
            @ConcurrentContract
            final class QueueSpec {
                @SystemUnderTest var queue: MyQueue

                @Oracle
                func equivalent(to other: MyQueue) -> Bool { true }

                @Command(weight: 3, .int(in: 0...9))
                func enqueue(value: Int) throws {
                }
            }
            """,
            expandedSource: """
            final class QueueSpec {
                var queue: MyQueue

                func equivalent(to other: MyQueue) -> Bool { true }

                func enqueue(value: Int) throws {
                }

                enum Command: CustomStringConvertible, Sendable {
                    case enqueue(value: Int)

                    var description: String {
                        switch self {
                            case let .enqueue(value): "enqueue(\\(value))"
                        }
                    }
                }

                typealias SystemUnderTest = MyQueue

                var systemUnderTest: SystemUnderTest {
                    queue
                }

                static var commandGenerator: ReflectiveGenerator<Command> {
                    .oneOf(weighted:
                        (3, #gen((.int(in: 0...9) as ReflectiveGenerator<Int>)) { value in Command.enqueue(value: value) })
                    )
                }

                func run(_ command: Command) throws {
                    switch command {
                        case let .enqueue(value): try self.enqueue(value: value)
                    }
                }

                func checkInvariants() throws {
                }

                var modelDescription: String {
                    "(no model properties)"
                }

                var sutDescription: String {
                    "queue: \\(queue)"
                }

                func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool {
                    equivalent(to: sequentialResult)
                }

                required init() {
                }
            }

            extension QueueSpec: ConcurrentContractSpec {
            }
            """,
            macros: concurrentMacros
        )
    }
}
