#if os(macOS)
    import MacroTesting
    import SwiftDiagnostics
    import SwiftSyntax
    import SwiftSyntaxBuilder
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "@Exhaustable declaration validation",
        .macros(["Exhaustable": ExhaustableMacro.self], record: .failed)
    )
    struct ExhaustableValidationTests {
        @Test("An initialized struct constant is diagnosed rather than omitted")
        func initializedStructConstant() {
            assertMacro {
                """
                @Exhaustable
                struct Value {
                    let count: Int = 3
                }
                """
            } diagnostics: {
                """
                @Exhaustable
                ┬───────────
                ╰─ 🛑 @Exhaustable does not support initialized let properties; write a generator for this type instead
                struct Value {
                    let count: Int = 3
                }
                """
            }
        }

        @Test("An initialized class constant produces no duplicate assignment")
        func initializedClassConstant() {
            assertMacro {
                """
                @Exhaustable
                final class Value {
                    let count: Int = 3
                }
                """
            } diagnostics: {
                """
                @Exhaustable
                ┬───────────
                ╰─ 🛑 @Exhaustable does not support initialized let properties; write a generator for this type instead
                final class Value {
                    let count: Int = 3
                }
                """
            }
        }

        @Test("An existing class initializer is not duplicated")
        func existingClassInitializer() {
            assertMacro {
                """
                @Exhaustable
                final class Value {
                    let count: Int
                    init(count: Int) { self.count = count }
                }
                """
            } diagnostics: {
                """
                @Exhaustable
                ┬───────────
                ╰─ 🛑 @Exhaustable requires memberwise construction without in-body initializers; move struct initializers to an extension or write a generator for this type instead
                final class Value {
                    let count: Int
                    init(count: Int) { self.count = count }
                }
                """
            }
        }

        @Test("A subclass is diagnosed instead of omitting superclass initialization")
        func rejectsSubclass() {
            assertMacro {
                """
                @Exhaustable
                final class Value: Parent {
                    let count: Int
                }
                """
            } diagnostics: {
                """
                @Exhaustable
                ┬───────────
                ╰─ 🛑 @Exhaustable requires a final class without an inheritance clause; put protocol conformances in extensions
                final class Value: Parent {
                    let count: Int
                }
                """
            }
        }

        @Test("Both roles reject the same unsupported construction without partial expansion")
        func rolesShareValidation() throws {
            let declarations: [(source: String, diagnostic: ExhaustableDiagnostic)] = [
                ("struct Example { let count: Int = 3 }", .initializedConstantUnsupported),
                ("final class Example { let count: Int = 3 }", .initializedConstantUnsupported),
                ("struct Example {\nlet count: Int\ninit(_ count: Int) { self.count = count }\n}", .customInitializerUnsupported),
                ("final class Example {\nlet count: Int\ninit(count: Int) { self.count = count }\n}", .customInitializerUnsupported),
                ("final class Example: Parent { let count: Int }", .classInheritanceUnsupported),
                ("final class Example: Sendable { let count: Int }", .classInheritanceUnsupported),
                ("final class Example<Value> { let count: Int }", .genericUnsupported),
                ("struct Example<Value> { let value: Value }", .genericUnsupported),
                ("enum Example<Value> { case value(Value) }", .genericUnsupported),
                ("final class Example { var count = 0 }", .propertyNeedsTypeAnnotation),
                ("struct Example { @Wrapper var count: Int }", .propertyAttributesUnsupported),
                ("final class Example { @Wrapper var count: Int }", .propertyAttributesUnsupported),
                ("struct Example { lazy var count: Int = 3 }", .propertyStorageUnsupported),
                ("final class Example { weak var parent: Parent? }", .propertyStorageUnsupported),
                ("final class Example { unowned let parent: Parent }", .propertyStorageUnsupported),
                ("struct Example { var (first, second): (Int, Int) }", .propertyPatternUnsupported),
                ("class Example { let count: Int }", .classMustBeFinal),
                ("actor Example { let count: Int }", .requiresEnumStructOrFinalClass),
                ("struct Example {\n#if DEBUG\nvar count: Int\n#endif\n}", .conditionalMembersUnsupported),
                ("enum Example {\n#if DEBUG\ncase value\n#endif\n}", .conditionalMembersUnsupported),
            ]
            for entry in declarations {
                let syntax = DeclSyntax(stringLiteral: entry.source)
                let declaration = try #require(syntax.asProtocol(DeclGroupSyntax.self))
                let attribute: AttributeSyntax = "@Exhaustable"
                let context = GenerableValidationContext()
                let members = try ExhaustableMacro.expansion(
                    of: attribute,
                    providingMembersOf: declaration,
                    conformingTo: [],
                    in: context
                )
                #expect(members.isEmpty, "\(entry.source)")
                #expect(context.diagnostics.isEmpty)
                let extensions = try ExhaustableMacro.expansion(
                    of: attribute,
                    attachedTo: declaration,
                    providingExtensionsOf: IdentifierTypeSyntax(name: .identifier("Example")),
                    conformingTo: [],
                    in: context
                )
                #expect(extensions.isEmpty, "\(entry.source)")
                #expect(context.diagnostics.map(\.diagMessage.diagnosticID) == [entry.diagnostic.diagnosticID], "\(entry.source)")
            }
        }

        @Test("A struct can preserve an explicit direct memberwise initializer")
        func directMemberwiseInitializer() throws {
            let declaration: DeclSyntax = """
            public struct Example {
                public var count: Int
                public var label: String
                public init(count: Int, label: String) {
                    self.count = count
                    self.label = label
                }
            }
            """
            let structure = try #require(declaration.as(StructDeclSyntax.self))
            let model = try ExhaustableDeclaration.validate(structure, lexicalContext: [])
            guard case let .memberwise(properties) = model.construction else {
                Issue.record("Expected direct memberwise construction")
                return
            }
            #expect(model.access == "public ")
            #expect(properties.map(\.name) == ["count", "label"])
            let context = GenerableValidationContext()
            let extensions = try ExhaustableMacro.expansion(
                of: AttributeSyntax("@Exhaustable"),
                attachedTo: structure,
                providingExtensionsOf: IdentifierTypeSyntax(name: .identifier("Example")),
                conformingTo: [],
                in: context
            )
            #expect(extensions.count == 1)
            #expect(context.diagnostics.isEmpty)
            let expansion = try #require(extensions.first)
            #expect(expansion.trimmedDescription.contains("Example(count: values[0] as! Int, label: values[1] as! String)"))
        }

        @Test("Explicit memberwise construction rejects altered values, labels, types, effects, and overloads")
        func rejectsNonMemberwiseInitializers() throws {
            let initializers = [
                "init(count: Int) { self.count = count + 1 }",
                "init(count: Int) { self.count = 0 }",
                "init(_ count: Int) { self.count = count }",
                "init(count value: Int) { self.count = value }",
                "init(count: Int = 0) { self.count = count }",
                "init(count: Int...) { self.count = count[0] }",
                "init(count: UInt) { self.count = count }",
                "init(count: Int) throws { self.count = count }",
                "init?(count: Int) { self.count = count }",
                "init(count: Int) { self.count = count\nprint(count) }",
                "init(count: Int) { self.count = count }\ninit() { self.count = 0 }",
                "init(count: Int) {}",
            ]
            for initializer in initializers {
                let declaration = DeclSyntax(stringLiteral: "struct Example { var count: Int\n\(initializer) }")
                let structure = try #require(declaration.as(StructDeclSyntax.self))
                #expect(throws: ExhaustableDiagnostic.customInitializerUnsupported, "\(initializer)") {
                    try ExhaustableDeclaration.validate(structure, lexicalContext: [])
                }
            }
        }

        @Test("Generated access prefixes respect declaration and enclosing visibility")
        func accessPrefixes() throws {
            let cases = [
                (modifier: "private", enclosing: "public", prefix: "fileprivate "),
                (modifier: "fileprivate", enclosing: "package", prefix: "fileprivate "),
                (modifier: "", enclosing: "public", prefix: ""),
                (modifier: "internal", enclosing: "public", prefix: ""),
                (modifier: "package", enclosing: "public", prefix: "package "),
                (modifier: "public", enclosing: "public", prefix: "public "),
                (modifier: "public", enclosing: "open", prefix: "public "),
                (modifier: "public", enclosing: "private", prefix: "fileprivate "),
                (modifier: "public", enclosing: "fileprivate", prefix: "fileprivate "),
                (modifier: "public", enclosing: "internal", prefix: ""),
                (modifier: "public", enclosing: "", prefix: ""),
                (modifier: "public", enclosing: "package", prefix: "package "),
            ]
            for entry in cases {
                let declaration = DeclSyntax(stringLiteral: "\(entry.modifier) struct Value { let count: Int }")
                let structure = try #require(declaration.as(StructDeclSyntax.self))
                let outer = DeclSyntax(stringLiteral: "\(entry.enclosing) class Container {}")
                let model = try ExhaustableDeclaration.validate(structure, lexicalContext: [Syntax(outer)])
                #expect(model.access == entry.prefix, "\(entry.modifier) inside \(entry.enclosing)")
            }
        }

        @Test("A nongeneric nested declaration still rejects a generic enclosing scope")
        func rejectsGenericEnclosingScope() throws {
            let nested: DeclSyntax = "struct Value { let count: Int }"
            let structure = try #require(nested.as(StructDeclSyntax.self))
            for kind in ["struct", "enum", "class", "actor"] {
                let outer = DeclSyntax(stringLiteral: "\(kind) Container<Element> {}")
                #expect(throws: ExhaustableDiagnostic.genericUnsupported) {
                    try ExhaustableDeclaration.validate(structure, lexicalContext: [Syntax(outer)])
                }
            }
        }

        @Test("A product model retains mutability and default expressions with nonoptional types")
        func retainsConstructionInformation() throws {
            let declaration: DeclSyntax = """
            struct Value {
                let count: Int
                var label: String = "initial"
                var observed: Int = 0 { didSet {} }
                static let ignored = 42
                var computed: Int { count * 2 }
            }
            """
            let structure = try #require(declaration.as(StructDeclSyntax.self))
            let model = try ExhaustableDeclaration.validate(structure, lexicalContext: [])
            guard case let .memberwise(properties) = model.construction else {
                Issue.record("Expected Swift's memberwise construction strategy")
                return
            }
            #expect(properties.map(\.name) == ["count", "label", "observed"])
            #expect(properties.map { $0.type.trimmedDescription } == ["Int", "String", "Int"])
            #expect(properties.map(\.isMutable) == [false, true, true])
            #expect(properties.map { $0.initialValue?.trimmedDescription } == [nil, "\"initial\"", "0"])
        }
    }

    private final class GenerableValidationContext: MacroExpansionContext {
        private(set) var diagnostics: [Diagnostic] = []
        var lexicalContext: [Syntax] = []

        func makeUniqueName(_ name: String) -> TokenSyntax {
            .identifier("__generable_validation_\(name)")
        }

        func diagnose(_ diagnostic: Diagnostic) {
            diagnostics.append(diagnostic)
        }

        func location(
            of _: some SyntaxProtocol,
            at _: PositionInSyntaxNode,
            filePathMode _: SourceLocationFilePathMode
        ) -> AbstractSourceLocation? {
            AbstractSourceLocation(file: "\"Validation/Fixture.swift\"", line: "1", column: "1")
        }
    }
#endif
