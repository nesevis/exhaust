#if os(macOS)
    import SwiftDiagnostics
    import SwiftSyntax
    import SwiftSyntaxBuilder
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    @Suite("Compiler macro architectural review")
    struct CompilerMacroReviewTests {
        @Test("Forward-only #gen fallbacks emit reason-specific warnings")
        func forwardOnlyFallbacksEmitWarnings() throws {
            let testCases: [(source: ExprSyntax, expectedDiagnostic: ExhaustMacroDiagnostic)] = [
                (
                    "#gen(firstGenerator, secondGenerator) { Pair($0, $0) }",
                    .forwardOnlyShorthandParams
                ),
                (
                    """
                    #gen(intGenerator) { value in
                        let doubled = value * 2
                        return doubled
                    }
                    """,
                    .forwardOnlyMultiStatement
                ),
                (
                    "#gen(intGenerator) { value in value * 2 }",
                    .forwardOnlyNotFunctionCall
                ),
                (
                    "#gen(firstGenerator, secondGenerator) { first, second in Pair(first, second) }",
                    .forwardOnlyUnlabeledArguments
                ),
                (
                    "#gen(intGenerator) { value in Box(value: value * 2) }",
                    .forwardOnlyComplexArguments
                ),
                (
                    "#gen(intGenerator) { value in Box(value: other) }",
                    .forwardOnlyParamMismatch
                ),
            ]

            for testCase in testCases {
                let expansion = try #require(
                    testCase.source.as(MacroExpansionExprSyntax.self)
                )
                let context = RecordingMacroExpansionContext()

                _ = try GenerateMacro.expansion(of: expansion, in: context)

                #expect(context.diagnostics.count == 1)
                #expect(context.diagnostics.first?.diagMessage.severity == .warning)
                #expect(
                    context.diagnostics.first?.diagMessage.diagnosticID
                        == testCase.expectedDiagnostic.diagnosticID
                )
            }
        }

        @Test("Command parameters do not capture generated dispatch locals")
        func commandParametersDoNotCaptureGeneratedDispatchLocals() {
            let command = CommandInfo(
                methodName: "echo",
                parameters: [
                    CommandParameter(
                        externalLabel: "command",
                        bindingName: "command",
                        type: "String"
                    ),
                    CommandParameter(
                        externalLabel: "result",
                        bindingName: "result",
                        type: "String"
                    ),
                ],
                weight: "1",
                generatorExprs: [".string()", ".string()"],
                isAsync: false,
                isThrows: false,
                returnType: "String",
                syntax: nil
            )

            let expansion = synthesizeRunMethod(
                commands: [command],
                hasAnyAsync: false,
                access: ""
            ).trimmedDescription

            #expect(expansion.contains("func run(_ commandValue: Command) throws"))
            #expect(expansion.contains("switch commandValue"))
            #expect(expansion.contains("self.echo(command: command, result: result)"))
            #expect(expansion.contains("let resultValue ="))
            #expect(
                expansion.contains(
                    "CommandResponse(commandDescription: commandValue.description, returnValue: resultValue)"
                )
            )
        }

        @Test("An invariant with parameters is diagnosed")
        func invariantWithParametersIsDiagnosed() throws {
            let attribute: AttributeSyntax = "@StateMachine(.sequential)"
            let declaration: DeclSyntax = """
            final class InvalidInvariantSpec {
              @SystemUnderTest var counter: Counter

              @Command
              func increment() {}

              @Invariant
              func valid(after step: Int) -> Bool { true }
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

            #expect(
                context.diagnostics.map(\.diagMessage.diagnosticID) == [
                    StateMachineDiagnostic.invariantHasParameters.diagnosticID,
                ]
            )
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

            #expect(
                context.diagnostics.map(\.diagMessage.diagnosticID) == [
                    StateMachineDiagnostic.throwingOracle.diagnosticID,
                ]
            )
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

            #expect(
                context.diagnostics.map(\.diagMessage.diagnosticID) == [
                    StateMachineDiagnostic.mainActorCommand.diagnosticID,
                ]
            )
        }

        @Test("A type-isolated command is diagnosed before nonisolated synthesis")
        func typeIsolatedCommandIsDiagnosed() throws {
            let attribute: AttributeSyntax = "@StateMachine(.sequential)"
            let declaration: DeclSyntax = """
            @MainActor
            final class IsolatedCommandSpec {
              @SystemUnderTest var counter: Counter

              @Command
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

            #expect(
                context.diagnostics.map(\.diagMessage.diagnosticID) == [
                    StateMachineDiagnostic.mainActorCommand.diagnosticID,
                ]
            )
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
