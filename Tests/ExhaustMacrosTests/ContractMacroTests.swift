import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "exhaust": ExhaustContractMacro.self,
    "Contract": ContractDeclarationMacro.self,
    "Model": ModelMacro.self,
    "SUT": SUTMacro.self,
    "Command": CommandMacro.self,
    "Invariant": InvariantMacro.self,
]

private let asyncTestMacros: [String: any Macro.Type] = [
    "exhaust": ExhaustAsyncContractMacro.self,
    "Contract": ContractDeclarationMacro.self,
    "Model": ModelMacro.self,
    "SUT": SUTMacro.self,
    "Command": CommandMacro.self,
    "Invariant": InvariantMacro.self,
]

@Suite("#exhaust contract macro expansion tests")
struct ContractMacroTests {
    @Test("Basic #exhaust contract expansion")
    func basicContract() {
        assertMacroExpansion(
            """
            #exhaust(BoundedQueueSpec.self, commandLimit: 20)
            """,
            expandedSource: """
            __runContract(
                BoundedQueueSpec.self,
                commandLimit: 20,
                settings: [],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("#exhaust contract with settings")
    func contractWithSettings() {
        assertMacroExpansion(
            """
            #exhaust(Spec.self, commandLimit: 20, .maxIterations(500))
            """,
            expandedSource: """
            __runContract(
                Spec.self,
                commandLimit: 20,
                settings: [.maxIterations(500)],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("#exhaust contract without commandLimit")
    func contractWithoutCommandLimit() {
        assertMacroExpansion(
            """
            #exhaust(Spec.self)
            """,
            expandedSource: """
            __runContract(
                Spec.self,
                commandLimit: nil,
                settings: [],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("#exhaust contract without commandLimit but with settings")
    func contractWithoutCommandLimitWithSettings() {
        assertMacroExpansion(
            """
            #exhaust(Spec.self, .suppressIssueReporting)
            """,
            expandedSource: """
            __runContract(
                Spec.self,
                commandLimit: nil,
                settings: [.suppressIssueReporting],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }
}

@Suite("@Contract declaration macro tests")
struct ContractDeclarationMacroTests {
    @Test("Synthesizes Command enum, SUT typealias, and conformance")
    func synthesizesFullSpec() {
        assertMacroExpansion(
            """
            @Contract
            struct QueueSpec {
                @Model var contents: [Int] = []
                @SUT var queue: MyQueue

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
            """,
            expandedSource: """
            struct QueueSpec {
                var contents: [Int] = []
                var queue: MyQueue

                mutating func enqueue(value: Int) throws {
                }

                mutating func dequeue() throws {
                }

                func countMatches() -> Bool {
                    true
                }

                enum Command: CustomStringConvertible, Sendable {
                    case enqueue(value: Int)
                    case dequeue

                    var description: String {
                        switch self {
                            case let .enqueue(value): "enqueue(\\(value))"
                            case .dequeue: "dequeue"
                        }
                    }
                }

                typealias SystemUnderTest = MyQueue

                var sut: SystemUnderTest {
                    queue
                }

                static var commandGenerator: ReflectiveGenerator<Command> {
                    .oneOf(weighted:
                        (3, .just(Command.enqueue)),
                        (2, .just(Command.dequeue))
                    )
                }

                mutating func run(_ command: Command) throws {
                    switch command {
                        case .enqueue(let value): try self.enqueue(value: value)
                        case .dequeue: try self.dequeue()
                    }
                }

                func checkInvariants() throws {
                    try check(countMatches(), "countMatches")
                }

                var modelDescription: String {
                    "contents: \\(contents)"
                }

                var sutDescription: String {
                    "queue: \\(queue)"
                }
            }

            extension QueueSpec: ContractSpec {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Marker macros produce no peer declarations")
    func markerMacrosAreEmpty() {
        assertMacroExpansion(
            """
            @Model var x: Int = 0
            """,
            expandedSource: """
            var x: Int = 0
            """,
            macros: testMacros
        )
    }

    @Test("Async command produces AsyncContractSpec conformance and async run/checkInvariants")
    func asyncCommandSynthesizesAsyncConformance() {
        assertMacroExpansion(
            """
            @Contract
            struct AsyncSpec {
                @SUT var counter: MyCounter

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
            """,
            expandedSource: """
            struct AsyncSpec {
                var counter: MyCounter

                mutating func increment() async throws {
                }

                mutating func decrement() throws {
                }

                func isValid() -> Bool {
                    true
                }

                enum Command: CustomStringConvertible, Sendable {
                    case increment
                    case decrement

                    var description: String {
                        switch self {
                            case .increment: "increment"
                            case .decrement: "decrement"
                        }
                    }
                }

                typealias SystemUnderTest = MyCounter

                var sut: SystemUnderTest {
                    counter
                }

                static var commandGenerator: ReflectiveGenerator<Command> {
                    .oneOf(weighted:
                        (1, .just(Command.increment)),
                        (1, .just(Command.decrement))
                    )
                }

                mutating func run(_ command: Command) async throws {
                    switch command {
                        case .increment: try await self.increment()
                        case .decrement: try await self.decrement()
                    }
                }

                func checkInvariants() async throws {
                    try check(isValid(), "isValid")
                }

                var modelDescription: String {
                    "(no model properties)"
                }

                var sutDescription: String {
                    "counter: \\(counter)"
                }
            }

            extension AsyncSpec: AsyncContractSpec {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Async invariant produces AsyncContractSpec conformance")
    func asyncInvariantSynthesizesAsyncConformance() {
        assertMacroExpansion(
            """
            @Contract
            struct AsyncInvSpec {
                @SUT var counter: MyCounter

                @Command(weight: 1)
                mutating func increment() throws {
                }

                @Invariant
                func isValid() async -> Bool {
                    true
                }
            }
            """,
            expandedSource: """
            struct AsyncInvSpec {
                var counter: MyCounter

                mutating func increment() throws {
                }

                func isValid() async -> Bool {
                    true
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

                var sut: SystemUnderTest {
                    counter
                }

                static var commandGenerator: ReflectiveGenerator<Command> {
                    .oneOf(weighted:
                        (1, .just(Command.increment))
                    )
                }

                mutating func run(_ command: Command) async throws {
                    switch command {
                        case .increment: try await self.increment()
                    }
                }

                func checkInvariants() async throws {
                    let isValidResult = await isValid()
                    try check(isValidResult, "isValid")
                }

                var modelDescription: String {
                    "(no model properties)"
                }

                var sutDescription: String {
                    "counter: \\(counter)"
                }
            }

            extension AsyncInvSpec: AsyncContractSpec {
            }
            """,
            macros: testMacros
        )
    }

    @Test("All-sync commands still produce ContractSpec conformance")
    func allSyncCommandsProduceSyncConformance() {
        assertMacroExpansion(
            """
            @Contract
            struct SyncSpec {
                @SUT var counter: MyCounter

                @Command(weight: 1)
                mutating func increment() throws {
                }
            }
            """,
            expandedSource: """
            struct SyncSpec {
                var counter: MyCounter

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

                var sut: SystemUnderTest {
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
            }

            extension SyncSpec: ContractSpec {
            }
            """,
            macros: testMacros
        )
    }
}

@Suite("#exhaust async contract macro expansion tests")
struct AsyncContractMacroTests {
    @Test("#exhaust async contract expansion")
    func asyncContractExpansion() {
        assertMacroExpansion(
            """
            #exhaust(AsyncSpec.self, commandLimit: 20)
            """,
            expandedSource: """
            __runContractAsync(
                AsyncSpec.self,
                commandLimit: 20,
                settings: [],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: asyncTestMacros
        )
    }

    @Test("#exhaust async contract with settings")
    func asyncContractWithSettings() {
        assertMacroExpansion(
            """
            #exhaust(AsyncSpec.self, commandLimit: 10, .maxIterations(50))
            """,
            expandedSource: """
            __runContractAsync(
                AsyncSpec.self,
                commandLimit: 10,
                settings: [.maxIterations(50)],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: asyncTestMacros
        )
    }
}
