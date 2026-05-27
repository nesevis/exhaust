import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "exhaust": ExhaustContractMacro.self,
    "Contract": ContractDeclarationMacro.self,
    "Model": ModelMacro.self,
    "SystemUnderTest": SUTMacro.self,
    "Command": CommandMacro.self,
    "Invariant": InvariantMacro.self,
]

private let asyncTestMacros: [String: any Macro.Type] = [
    "exhaust": ExhaustConcurrentContractMacro.self,
    "Contract": ContractDeclarationMacro.self,
    "Model": ModelMacro.self,
    "SystemUnderTest": SUTMacro.self,
    "Command": CommandMacro.self,
    "Invariant": InvariantMacro.self,
]

@Suite("#exhaust contract macro expansion tests")
struct ContractMacroTests {
    @Test("Basic #exhaust contract expansion with commandLimit")
    func basicExhaustContractExpansionWithCommandLimit() {
        assertMacroExpansion(
            """
            #exhaust(BoundedQueueSpec.self, .commandLimit(20))
            """,
            expandedSource: """
            __ExhaustRuntime.__runContract(
                BoundedQueueSpec.self,
                settings: [.commandLimit(20)],
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
    func exhaustContractWithSettings() {
        assertMacroExpansion(
            """
            #exhaust(Spec.self, .commandLimit(20), .budget(.thorough))
            """,
            expandedSource: """
            __ExhaustRuntime.__runContract(
                Spec.self,
                settings: [.commandLimit(20), .budget(.thorough)],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros
        )
    }

    @Test("#exhaust contract with no settings")
    func exhaustContractWithNoSettings() {
        assertMacroExpansion(
            """
            #exhaust(Spec.self)
            """,
            expandedSource: """
            __ExhaustRuntime.__runContract(
                Spec.self,
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

    @Test("#exhaust contract with suppress only")
    func exhaustContractWithSuppressOnly() {
        assertMacroExpansion(
            """
            #exhaust(Spec.self, .suppress(.issueReporting))
            """,
            expandedSource: """
            __ExhaustRuntime.__runContract(
                Spec.self,
                settings: [.suppress(.issueReporting)],
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
    func synthesizesCommandEnumSUTTypealiasAndConformance() {
        assertMacroExpansion(
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

                var systemUnderTest: SystemUnderTest {
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
                        case let .enqueue(value): try self.enqueue(value: value)
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
    func markerMacrosProduceNoPeerDeclarations() {
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
    func asyncCommandProducesAsyncContractSpecConformanceAndAsyncRuncheckInvariants() {
        assertMacroExpansion(
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

                var systemUnderTest: SystemUnderTest {
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
                        case .decrement: try self.decrement()
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
    func asyncInvariantProducesAsyncContractSpecConformance() {
        assertMacroExpansion(
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

                var systemUnderTest: SystemUnderTest {
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
    func allSyncCommandsStillProduceContractSpecConformance() {
        assertMacroExpansion(
            """
            @Contract
            struct SyncSpec {
                @SystemUnderTest var counter: MyCounter

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
            }

            extension SyncSpec: ContractSpec {
            }
            """,
            macros: testMacros
        )
    }

    @Test("@Command with generator expression produces #gen in commandGenerator")
    func commandWithGeneratorExpressionProducesGenInCommandGenerator() {
        assertMacroExpansion(
            """
            @Contract
            struct InsertSpec {
                @SystemUnderTest var items: [Int]

                @Command(weight: 3, .int(in: 0...99))
                mutating func insert(value: Int) throws {
                }
            }
            """,
            expandedSource: """
            struct InsertSpec {
                var items: [Int]

                mutating func insert(value: Int) throws {
                }

                enum Command: CustomStringConvertible, Sendable {
                    case insert(value: Int)

                    var description: String {
                        switch self {
                            case let .insert(value): "insert(\\(value))"
                        }
                    }
                }

                typealias SystemUnderTest = [Int]

                var systemUnderTest: SystemUnderTest {
                    items
                }

                static var commandGenerator: ReflectiveGenerator<Command> {
                    .oneOf(weighted:
                        (3, #gen((.int(in: 0...99) as ReflectiveGenerator<Int>)) { value in Command.insert(value: value) })
                    )
                }

                mutating func run(_ command: Command) throws {
                    switch command {
                        case let .insert(value): try self.insert(value: value)
                    }
                }

                func checkInvariants() throws {
                }

                var modelDescription: String {
                    "(no model properties)"
                }

                var sutDescription: String {
                    "items: \\(items)"
                }
            }

            extension InsertSpec: ContractSpec {
            }
            """,
            macros: testMacros
        )
    }
}

@Suite("@Contract tab indentation tests")
struct ContractTabIndentationTests {
    @Test("@Contract with tab indentation synthesizes correctly indented members")
    func contractWithTabIndentationSynthesizesCorrectlyIndentedMembers() {
        assertMacroExpansion(
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
            """,
            expandedSource: """
            struct QueueSpec {
            \tvar contents: [Int] = []
            \tvar queue: MyQueue

            \tmutating func enqueue(value: Int) throws {
            \t}

            \tmutating func dequeue() throws {
            \t}

            \tfunc countMatches() -> Bool {
            \t\ttrue
            \t}

            \tenum Command: CustomStringConvertible, Sendable {
            \t\tcase enqueue(value: Int)
            \t\tcase dequeue

            \t\tvar description: String {
            \t\t\tswitch self {
            \t\t\t\tcase let .enqueue(value): "enqueue(\\(value))"
            \t\t\t\tcase .dequeue: "dequeue"
            \t\t\t}
            \t\t}
            \t}

            \ttypealias SystemUnderTest = MyQueue

            \tvar systemUnderTest: SystemUnderTest {
            \t\tqueue
            \t}

            \tstatic var commandGenerator: ReflectiveGenerator<Command> {
            \t\t.oneOf(weighted:
            \t\t\t(3, .just(Command.enqueue)),
            \t\t\t(2, .just(Command.dequeue))
            \t\t)
            \t}

            \tmutating func run(_ command: Command) throws {
            \t\tswitch command {
            \t\t\tcase let .enqueue(value): try self.enqueue(value: value)
            \t\t\tcase .dequeue: try self.dequeue()
            \t\t}
            \t}

            \tfunc checkInvariants() throws {
            \t\ttry check(countMatches(), "countMatches")
            \t}

            \tvar modelDescription: String {
            \t\t"contents: \\(contents)"
            \t}

            \tvar sutDescription: String {
            \t\t"queue: \\(queue)"
            \t}
            }

            extension QueueSpec: ContractSpec {
            }
            """,
            macros: testMacros,
            indentationWidth: .tabs(1)
        )
    }

    @Test("@Contract with tab indentation and generator expressions")
    func contractWithTabIndentationAndGeneratorExpressions() {
        assertMacroExpansion(
            """
            @Contract
            struct InsertSpec {
            \t@SystemUnderTest var items: [Int]

            \t@Command(weight: 3, .int(in: 0...99))
            \tmutating func insert(value: Int) throws {
            \t}
            }
            """,
            expandedSource: """
            struct InsertSpec {
            \tvar items: [Int]

            \tmutating func insert(value: Int) throws {
            \t}

            \tenum Command: CustomStringConvertible, Sendable {
            \t\tcase insert(value: Int)

            \t\tvar description: String {
            \t\t\tswitch self {
            \t\t\t\tcase let .insert(value): "insert(\\(value))"
            \t\t\t}
            \t\t}
            \t}

            \ttypealias SystemUnderTest = [Int]

            \tvar systemUnderTest: SystemUnderTest {
            \t\titems
            \t}

            \tstatic var commandGenerator: ReflectiveGenerator<Command> {
            \t\t.oneOf(weighted:
            \t\t\t(3, #gen((.int(in: 0...99) as ReflectiveGenerator<Int>)) { value in Command.insert(value: value) })
            \t\t)
            \t}

            \tmutating func run(_ command: Command) throws {
            \t\tswitch command {
            \t\t\tcase let .insert(value): try self.insert(value: value)
            \t\t}
            \t}

            \tfunc checkInvariants() throws {
            \t}

            \tvar modelDescription: String {
            \t\t"(no model properties)"
            \t}

            \tvar sutDescription: String {
            \t\t"items: \\(items)"
            \t}
            }

            extension InsertSpec: ContractSpec {
            }
            """,
            macros: testMacros,
            indentationWidth: .tabs(1)
        )
    }

    @Test("@Contract with tab indentation and multiple model properties")
    func contractWithTabIndentationAndMultipleModelProperties() {
        assertMacroExpansion(
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
            """,
            expandedSource: """
            struct Spec {
            \tvar count: Int = 0
            \tvar name: String = ""
            \tvar sut: MySUT

            \tmutating func doSomething() throws {
            \t}

            \tenum Command: CustomStringConvertible, Sendable {
            \t\tcase doSomething

            \t\tvar description: String {
            \t\t\tswitch self {
            \t\t\t\tcase .doSomething: "doSomething"
            \t\t\t}
            \t\t}
            \t}

            \ttypealias SystemUnderTest = MySUT

            \tvar systemUnderTest: SystemUnderTest {
            \t\tsut
            \t}

            \tstatic var commandGenerator: ReflectiveGenerator<Command> {
            \t\t.oneOf(weighted:
            \t\t\t(1, .just(Command.doSomething))
            \t\t)
            \t}

            \tmutating func run(_ command: Command) throws {
            \t\tswitch command {
            \t\t\tcase .doSomething: try self.doSomething()
            \t\t}
            \t}

            \tfunc checkInvariants() throws {
            \t}

            \tvar modelDescription: String {
            \t\t[
            \t\t\t"  count: \\(count)",
            \t\t\t"  name: \\(name)"
            \t\t].joined(separator: "\\n")
            \t}

            \tvar sutDescription: String {
            \t\t"sut: \\(sut)"
            \t}
            }

            extension Spec: ContractSpec {
            }
            """,
            macros: testMacros,
            indentationWidth: .tabs(1)
        )
    }
}

@Suite("#exhaust async contract macro expansion tests")
struct AsyncContractMacroTests {
    @Test("#exhaust async contract expansion with no settings")
    func exhaustAsyncContractExpansionWithNoSettings() {
        assertMacroExpansion(
            """
            #exhaust(AsyncSpec.self)
            """,
            expandedSource: """
            __ExhaustRuntime.__runContractConcurrent(
                AsyncSpec.self,
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
    func exhaustAsyncContractWithSettings() {
        assertMacroExpansion(
            """
            #exhaust(AsyncSpec.self, .commandLimit(10), .concurrent(3))
            """,
            expandedSource: """
            __ExhaustRuntime.__runContractConcurrent(
                AsyncSpec.self,
                settings: [.commandLimit(10), .concurrent(3)],
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
