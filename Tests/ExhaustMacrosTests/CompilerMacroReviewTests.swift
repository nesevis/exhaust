#if os(macOS)
    import SwiftDiagnostics
    import SwiftSyntax
    import SwiftSyntaxBuilder
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    @Suite("Compiler macro architectural review")
    struct CompilerMacroReviewTests {
        @Test("A static factory call does not synthesize enum-case reflection")
        func staticFactoryCallUsesForwardOnlyMapping() throws {
            let closureExpression: ExprSyntax = "{ value in Factory.make(value: value) }"
            let closure = try #require(closureExpression.as(ClosureExprSyntax.self))

            let outcome = analyzeClosureForBidirectional(closure, generatorCount: 1)
            let isForwardOnly = switch outcome {
                case .forwardOnly: true
                case .bidirectional, .scalarConversion: false
            }

            #expect(isForwardOnly)
        }

        @Test("A forward-only #gen fallback emits its explanatory warning")
        func forwardOnlyFallbackEmitsWarning() throws {
            let expression: ExprSyntax = "#gen(intGenerator) { value in value * 2 }"
            let expansion = try #require(expression.as(MacroExpansionExprSyntax.self))
            let context = RecordingMacroExpansionContext()

            _ = try GenerateMacro.expansion(of: expansion, in: context)

            #expect(context.diagnostics.contains { diagnostic in
                diagnostic.diagMessage.severity == .warning
                    && diagnostic.message.contains("Cannot infer backward mapping")
            })
        }

        @Test("A parameter named command does not capture the response description source")
        func commandParameterDoesNotCaptureResponseDescription() {
            let command = CommandInfo(
                methodName: "echo",
                parameters: [
                    CommandParameter(
                        externalLabel: "command",
                        bindingName: "command",
                        type: "String"
                    ),
                ],
                weight: "1",
                generatorExprs: [".string()"],
                isAsync: false,
                isThrows: false,
                returnType: nil,
                syntax: nil
            )

            let expansion = synthesizeRunMethod(
                commands: [command],
                hasAnyAsync: false,
                access: ""
            ).trimmedDescription

            #expect(expansion.contains("commandDescription: command.description") == false)
        }

        @Test("An invariant with parameters and a non-Bool result is diagnosed")
        func invalidInvariantSignatureIsDiagnosed() throws {
            let attribute: AttributeSyntax = "@StateMachine(.sequential)"
            let declaration: DeclSyntax = """
            final class InvalidInvariantSpec {
              @SystemUnderTest var counter: Counter

              @Command
              func increment() {}

              @Invariant
              func valid(after step: Int) -> String { "invalid" }
            }
            """
            let classDeclaration = try #require(declaration.as(ClassDeclSyntax.self))
            let context = RecordingMacroExpansionContext()

            _ = try StateMachineDeclarationMacro.expansion(
                of: attribute,
                providingMembersOf: classDeclaration,
                conformingTo: [],
                in: context
            )

            #expect(context.diagnostics.contains { $0.diagMessage.severity == .error })
        }

        @Test("A throwing oracle is diagnosed before non-throwing synthesis")
        func throwingOracleIsDiagnosed() throws {
            let attribute: AttributeSyntax = "@StateMachine(.threads)"
            let declaration: DeclSyntax = """
            final class ThrowingOracleSpec {
              @SystemUnderTest var counter: Counter

              @Command
              func increment() {}

              @Oracle
              func equivalent(to other: Counter) throws -> Bool { true }
            }
            """
            let classDeclaration = try #require(declaration.as(ClassDeclSyntax.self))
            let context = RecordingMacroExpansionContext()

            _ = try StateMachineDeclarationMacro.expansion(
                of: attribute,
                providingMembersOf: classDeclaration,
                conformingTo: [],
                in: context
            )

            #expect(context.diagnostics.contains { $0.diagMessage.severity == .error })
        }

        @Test("A member-isolated command is diagnosed before nonisolated synthesis")
        func memberIsolatedCommandIsDiagnosed() throws {
            let attribute: AttributeSyntax = "@StateMachine(.sequential)"
            let declaration: DeclSyntax = """
            final class IsolatedCommandSpec {
              @SystemUnderTest var counter: Counter

              @Command
              @MainActor
              func increment() {}
            }
            """
            let classDeclaration = try #require(declaration.as(ClassDeclSyntax.self))
            let context = RecordingMacroExpansionContext()

            _ = try StateMachineDeclarationMacro.expansion(
                of: attribute,
                providingMembersOf: classDeclaration,
                conformingTo: [],
                in: context
            )

            #expect(context.diagnostics.contains { $0.diagMessage.severity == .error })
        }
    }

    private final class RecordingMacroExpansionContext: MacroExpansionContext {
        private(set) var diagnostics = [Diagnostic]()
        var lexicalContext = [Syntax]()

        func makeUniqueName(_ name: String) -> TokenSyntax {
            .identifier("__macro_review_\(name)")
        }

        func diagnose(_ diagnostic: Diagnostic) {
            diagnostics.append(diagnostic)
        }

        func location(
            of _: some SyntaxProtocol,
            at _: PositionInSyntaxNode,
            filePathMode _: SourceLocationFilePathMode
        ) -> AbstractSourceLocation? {
            nil
        }
    }
#endif
