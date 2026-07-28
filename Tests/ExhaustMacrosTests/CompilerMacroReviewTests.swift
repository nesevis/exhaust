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
            let declaration: DeclSyntax = """
            final class InvalidInvariantSpec {
              @SystemUnderTest var counter: Counter

              @Command
              func increment() {}

              @Invariant
              func valid(after step: Int) -> Bool { true }
            }
            """
            let diagnostics = try expansionDiagnostics(of: declaration)

            #expect(
                diagnostics.map(\.diagMessage.diagnosticID) == [
                    StateMachineDiagnostic.invariantHasParameters.diagnosticID,
                ]
            )
        }

        @Test("A throwing oracle is diagnosed before non-throwing synthesis")
        func throwingOracleIsDiagnosed() throws {
            let declaration: DeclSyntax = """
            final class ThrowingOracleSpec {
              @SystemUnderTest var counter: Counter

              @Command
              func increment() {}

              @Equivalence
              func equivalent(to other: Counter) throws -> Bool { true }
            }
            """
            let diagnostics = try expansionDiagnostics(of: declaration)

            #expect(
                diagnostics.map(\.diagMessage.diagnosticID) == [
                    StateMachineDiagnostic.throwingEquivalence.diagnosticID,
                ]
            )
        }

        @Test("A member-isolated command is diagnosed before nonisolated synthesis")
        func memberIsolatedCommandIsDiagnosed() throws {
            // The spec also has no failure channel, so it draws the cannot-fail warning first: spec-level checks run before the per-command loop. Both are named rather than matched loosely, so a third diagnostic appearing here is a test failure rather than something the assertion absorbs.
            let declaration: DeclSyntax = """
            final class IsolatedCommandSpec {
              @SystemUnderTest var counter: Counter

              @Command
              @MainActor
              func increment() {}
            }
            """
            let diagnostics = try expansionDiagnostics(of: declaration)

            #expect(
                diagnostics.map(\.diagMessage.diagnosticID) == [
                    StateMachineDiagnostic.specCannotFail.diagnosticID,
                    StateMachineDiagnostic.mainActorCommand.diagnosticID,
                ]
            )
        }

        @Test("A type-isolated command is diagnosed before nonisolated synthesis")
        func typeIsolatedCommandIsDiagnosed() throws {
            let declaration: DeclSyntax = """
            @MainActor
            final class IsolatedCommandSpec {
              @SystemUnderTest var counter: Counter

              @Command
              func increment() {}
            }
            """
            let diagnostics = try expansionDiagnostics(of: declaration)

            #expect(
                diagnostics.map(\.diagMessage.diagnosticID) == [
                    StateMachineDiagnostic.specCannotFail.diagnosticID,
                    StateMachineDiagnostic.mainActorCommand.diagnosticID,
                ]
            )
        }

        @Test("A spec with no invariant, no equivalence, and no throwing command warns that it cannot fail")
        func specWithNoFailureChannelIsDiagnosed() throws {
            let declaration: DeclSyntax = """
            final class UnfailableSpec {
              @SystemUnderTest var counter: Counter

              @Command
              func increment() {}
            }
            """
            let diagnostics = try expansionDiagnostics(of: declaration)

            #expect(
                diagnostics.map(\.diagMessage.diagnosticID) == [
                    StateMachineDiagnostic.specCannotFail.diagnosticID,
                ]
            )
            #expect(diagnostics.first?.diagMessage.severity == .warning)
        }

        @Test("An invariant is a failure channel, so the cannot-fail warning stays silent")
        func invariantSuppressesCannotFailWarning() throws {
            let declaration: DeclSyntax = """
            final class InvariantSpec {
              @SystemUnderTest var counter: Counter

              @Command
              func increment() {}

              @Invariant
              func valid() -> Bool { true }
            }
            """
            let diagnostics = try expansionDiagnostics(of: declaration)

            #expect(diagnostics.isEmpty)
        }

        @Test("An equivalence is a failure channel, so the cannot-fail warning stays silent")
        func equivalenceSuppressesCannotFailWarning() throws {
            let declaration: DeclSyntax = """
            final class EquivalenceSpec {
              @SystemUnderTest var counter: Counter

              @Command
              func increment() {}

              @Equivalence
              func equivalent(to other: Counter) -> Bool { true }
            }
            """
            let diagnostics = try expansionDiagnostics(of: declaration)

            #expect(diagnostics.isEmpty)
        }

        @Test("A throwing setup is a failure channel, so the cannot-fail warning stays silent")
        func throwingSetupSuppressesCannotFailWarning() throws {
            // `applySetup(_:)` returns the setup's error to the runner instead of rethrowing it, and every runner turns that into a failed sequence, so a spec that only judges its initial state can still fail.
            let declaration: DeclSyntax = """
            final class ThrowingSetupSpec {
              @SystemUnderTest var counter: Counter

              @Setup
              func prepare() throws {}

              @Command
              func increment() {}
            }
            """
            let diagnostics = try expansionDiagnostics(of: declaration)

            #expect(diagnostics.isEmpty)
        }

        @Test("A throwing command is a failure channel, so the cannot-fail warning stays silent")
        func throwingCommandSuppressesCannotFailWarning() throws {
            let declaration: DeclSyntax = """
            final class ThrowingCommandSpec {
              @SystemUnderTest var counter: Counter

              @Command
              func increment() throws {}
            }
            """
            let diagnostics = try expansionDiagnostics(of: declaration)

            #expect(diagnostics.isEmpty)
        }

        @Test("A spec with no commands gets the noCommands error alone, not the cannot-fail warning")
        func zeroCommandSpecIsNotDoubleDiagnosed() throws {
            let declaration: DeclSyntax = """
            final class EmptySpec {
              @SystemUnderTest var counter: Counter

              @Invariant
              func valid() -> Bool { true }
            }
            """
            let diagnostics = try expansionDiagnostics(of: declaration)

            #expect(
                diagnostics.map(\.diagMessage.diagnosticID) == [
                    StateMachineDiagnostic.noCommands.diagnosticID,
                ]
            )
        }

        /// Expands `@StateMachine` over the declaration and returns the diagnostics it emitted.
        private func expansionDiagnostics(of declaration: DeclSyntax) throws -> [Diagnostic] {
            let attribute: AttributeSyntax = "@StateMachine"
            let classDeclaration = try #require(declaration.as(ClassDeclSyntax.self))
            let context = RecordingMacroExpansionContext()

            _ = try StateMachineDeclarationMacro.expansion(
                of: attribute,
                providingMembersOf: classDeclaration,
                conformingTo: [],
                in: context
            )

            return context.diagnostics
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
