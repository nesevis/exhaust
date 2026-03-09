import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import ExhaustMacros

private let testMacros: [String: any Macro.Type] = [
    "exhaust": ExhaustStateMachineMacro.self,
    "StateMachine": StateMachineDeclarationMacro.self,
    "Model": ModelMacro.self,
    "SUT": SUTMacro.self,
    "Command": CommandMacro.self,
    "Invariant": InvariantMacro.self,
]

@Suite("#exhaust state-machine macro expansion tests")
struct StateMachineMacroTests {
    @Test("Basic #exhaust state-machine expansion")
    func basicStateMachine() {
        assertMacroExpansion(
            """
            #exhaust(BoundedQueueSpec.self)
            """,
            expandedSource: """
            __runStateMachine(
                BoundedQueueSpec.self,
                settings: [],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros,
        )
    }

    @Test("#exhaust state-machine with settings")
    func stateMachineWithSettings() {
        assertMacroExpansion(
            """
            #exhaust(Spec.self, .sequenceLength(5...20), .maxIterations(500))
            """,
            expandedSource: """
            __runStateMachine(
                Spec.self,
                settings: [.sequenceLength(5...20), .maxIterations(500)],
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """,
            macros: testMacros,
        )
    }
}

@Suite("@StateMachine declaration macro tests")
struct StateMachineDeclarationMacroTests {
    @Test("Synthesizes Command enum, SUT typealias, and conformance")
    func synthesizesFullSpec() {
        assertMacroExpansion(
            """
            @StateMachine
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
                    Gen.pick(choices: [
                        (3, Gen.just(Command.enqueue)),
                        (2, Gen.just(Command.dequeue))
                    ])
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

            extension QueueSpec: StateMachineSpec {
            }
            """,
            macros: testMacros,
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
            macros: testMacros,
        )
    }
}
