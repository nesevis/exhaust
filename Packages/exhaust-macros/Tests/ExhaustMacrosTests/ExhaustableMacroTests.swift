#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "@Exhaustable macro tests",
        .macros(["Exhaustable": ExhaustableMacro.self], record: .failed)
    )
    struct ExhaustableMacroTests {
        @Test("Cases with and without payloads expand to embed and extract pairs")
        func expandsCases() {
            assertMacro {
                """
                @Exhaustable
                public indirect enum Term {
                    case unit
                    case variable(Int)
                    case pair(Term, label: Term)
                }
                """
            } expansion: {
                """
                public indirect enum Term {
                    case unit
                    case variable(Int)
                    case pair(Term, label: Term)
                }

                extension Term: nonisolated __Exhaustable.Conformance {
                    public nonisolated static var __generatorDescriptor: __Exhaustable.TypeDescriptor<Term> {
                        __Exhaustable.TypeDescriptor(constructors: [
                            __Exhaustable.ConstructorDescriptor(name: "unit", payloadTypes: [], embed: { _ in
                                                Term.unit
                                            }, extract: { value in
                                                if case .unit = value {
                                                    return []
                                                } else {
                                                    return nil
                                                }
                                            }),
                                        __Exhaustable.ConstructorDescriptor(name: "variable", payloadTypes: [Int.self], embed: { values in
                                                Term.variable(values[0] as! Int)
                                            }, extract: { value in
                                                if case let .variable(value0) = value {
                                                    return [value0 as Any]
                                                } else {
                                                    return nil
                                                }
                                            }),
                                        __Exhaustable.ConstructorDescriptor(name: "pair", payloadTypes: [Term.self, Term.self], embed: { values in
                                                Term.pair(values[0] as! Term, label: values[1] as! Term)
                                            }, extract: { value in
                                                if case let .pair(value0, value1) = value {
                                                    return [value0 as Any, value1 as Any]
                                                } else {
                                                    return nil
                                                }
                                            })
                        ], fileID: "TestModule/Test.swift", line: 1, column: 1)
                    }
                }
                """
            }
        }

        @Test("A struct expands to one constructor over its stored properties")
        func expandsStruct() {
            assertMacro {
                """
                @Exhaustable
                struct Point {
                    let x: Int
                    var label: String = "origin"
                    static let zero = Point(x: 0)
                    var doubled: Int { x * 2 }
                    var observed: Int = 0 {
                        didSet { print(observed) }
                    }
                }
                """
            } expansion: {
                """
                struct Point {
                    let x: Int
                    var label: String = "origin"
                    static let zero = Point(x: 0)
                    var doubled: Int { x * 2 }
                    var observed: Int = 0 {
                        didSet { print(observed) }
                    }
                }

                extension Point: nonisolated __Exhaustable.Conformance {
                    nonisolated static var __generatorDescriptor: __Exhaustable.TypeDescriptor<Point> {
                        __Exhaustable.TypeDescriptor(constructors: [
                            __Exhaustable.ConstructorDescriptor(name: "Point", payloadTypes: [Int.self, String.self, Int.self], embed: { values in
                                                Point(x: values[0] as! Int, label: values[1] as! String, observed: values[2] as! Int)
                                            }, extract: { value in
                                                [value.x as Any, value.label as Any, value.observed as Any]
                                            })
                        ], fileID: "TestModule/Test.swift", line: 1, column: 1)
                    }
                }
                """
            }
        }

        @Test("A final class expands to one constructor and gains a memberwise initializer")
        func expandsFinalClass() {
            assertMacro {
                """
                @Exhaustable
                public final class Box {
                    let x: Int
                    var label: String = "box"
                }
                """
            } expansion: {
                """
                public final class Box {
                    let x: Int
                    var label: String = "box"

                    nonisolated init(x: Int, label: String) {
                        self.x = x
                        self.label = label
                    }
                }

                extension Box: nonisolated __Exhaustable.Conformance {
                    public nonisolated static var __generatorDescriptor: __Exhaustable.TypeDescriptor<Box> {
                        __Exhaustable.TypeDescriptor(constructors: [
                            __Exhaustable.ConstructorDescriptor(name: "Box", payloadTypes: [Int.self, String.self], embed: { values in
                                                Box(x: values[0] as! Int, label: values[1] as! String)
                                            }, extract: { value in
                                                [value.x as Any, value.label as Any]
                                            })
                        ], fileID: "TestModule/Test.swift", line: 1, column: 1)
                    }
                }
                """
            }
        }

        @Test("A version-gated case is appended behind an availability check")
        func expandsAvailableCase() {
            assertMacro {
                """
                @Exhaustable
                enum Signal {
                    case ready
                    @available(macOS 99, iOS 42, *)
                    case future
                    @available(*, unavailable)
                    case retired
                    @available(*, deprecated, message: "use ready")
                    case legacy
                }
                """
            } expansion: {
                """
                enum Signal {
                    case ready
                    @available(macOS 99, iOS 42, *)
                    case future
                    @available(*, unavailable)
                    case retired
                    @available(*, deprecated, message: "use ready")
                    case legacy
                }

                extension Signal: nonisolated __Exhaustable.Conformance {
                    nonisolated static var __generatorDescriptor: __Exhaustable.TypeDescriptor<Signal> {
                        var constructors: [__Exhaustable.ConstructorDescriptor<Signal>] = []
                        constructors.append(__Exhaustable.ConstructorDescriptor(name: "ready", payloadTypes: [], embed: { _ in
                                    Signal.ready
                                }, extract: { value in
                                    if case .ready = value {
                                        return []
                                    } else {
                                        return nil
                                    }
                                }))
                        if #available(macOS 99, iOS 42, *) {
                            constructors.append(__Exhaustable.ConstructorDescriptor(name: "future", payloadTypes: [], embed: { _ in
                                Signal.future
                            }, extract: { value in
                                if case .future = value {
                                    return []
                                } else {
                                    return nil
                                }
                            }))
                        }
                        constructors.append(__Exhaustable.ConstructorDescriptor(name: "legacy", payloadTypes: [], embed: { _ in
                                    Signal.legacy
                                }, extract: { value in
                                    if case .legacy = value {
                                        return []
                                    } else {
                                        return nil
                                    }
                                }))
                        return __Exhaustable.TypeDescriptor(constructors: constructors, fileID: "TestModule/Test.swift", line: 1, column: 1)
                    }
                }
                """
            }
        }

        @Test("A private payload restricts the generated initializer to the type's own scope")
        func expandsPrivatePayload() {
            assertMacro {
                """
                @Exhaustable
                final class Container {
                    private let hidden: Hidden
                    let count: Int
                }
                """
            } expansion: {
                """
                final class Container {
                    private let hidden: Hidden
                    let count: Int

                    private nonisolated init(hidden: Hidden, count: Int) {
                        self.hidden = hidden
                        self.count = count
                    }
                }

                extension Container: nonisolated __Exhaustable.Conformance {
                    nonisolated static var __generatorDescriptor: __Exhaustable.TypeDescriptor<Container> {
                        __Exhaustable.TypeDescriptor(constructors: [
                            __Exhaustable.ConstructorDescriptor(name: "Container", payloadTypes: [Hidden.self, Int.self], embed: { values in
                                                Container(hidden: values[0] as! Hidden, count: values[1] as! Int)
                                            }, extract: { value in
                                                [value.hidden as Any, value.count as Any]
                                            })
                        ], fileID: "TestModule/Test.swift", line: 1, column: 1)
                    }
                }
                """
            }
        }

        @Test("Budget and domain settings are carried onto the descriptor")
        func carriesSettings() {
            assertMacro {
                """
                @Exhaustable(.budget(.custom(recursion: 6, nodes: 31)), .domain(.small))
                indirect enum Expr {
                    case leaf
                    case node(Expr)
                }
                """
            } expansion: {
                """
                indirect enum Expr {
                    case leaf
                    case node(Expr)
                }

                extension Expr: nonisolated __Exhaustable.Conformance {
                    nonisolated static var __generatorDescriptor: __Exhaustable.TypeDescriptor<Expr> {
                        __Exhaustable.TypeDescriptor(constructors: [
                            __Exhaustable.ConstructorDescriptor(name: "leaf", payloadTypes: [], embed: { _ in
                                                Expr.leaf
                                            }, extract: { value in
                                                if case .leaf = value {
                                                    return []
                                                } else {
                                                    return nil
                                                }
                                            }),
                                        __Exhaustable.ConstructorDescriptor(name: "node", payloadTypes: [Expr.self], embed: { values in
                                                Expr.node(values[0] as! Expr)
                                            }, extract: { value in
                                                if case let .node(value0) = value {
                                                    return [value0 as Any]
                                                } else {
                                                    return nil
                                                }
                                            })
                        ], settings: [.budget(.custom(recursion: 6, nodes: 31)), .domain(.small)], fileID: "TestModule/Test.swift", line: 1, column: 1)
                    }
                }
                """
            }
        }

        @Test("A non-final class is rejected")
        func rejectsNonFinalClass() {
            assertMacro {
                """
                @Exhaustable
                class Box {
                    var x: Int = 0
                }
                """
            } diagnostics: {
                """
                @Exhaustable
                ┬───────────
                ╰─ 🛑 @Exhaustable requires a class to be final
                class Box {
                    var x: Int = 0
                }
                """
            }
        }

        @Test("An actor is rejected")
        func rejectsActor() {
            assertMacro {
                """
                @Exhaustable
                actor Vault {
                    var x: Int = 0
                }
                """
            } diagnostics: {
                """
                @Exhaustable
                ┬───────────
                ╰─ 🛑 @Exhaustable can only be attached to an enum, a struct, or a final class
                actor Vault {
                    var x: Int = 0
                }
                """
            }
        }

        @Test("A stored property without a type annotation is rejected")
        func rejectsInferredProperty() {
            assertMacro {
                """
                @Exhaustable
                struct Point {
                    var x = 0
                }
                """
            } diagnostics: {
                """
                @Exhaustable
                ┬───────────
                ╰─ 🛑 @Exhaustable needs a type annotation on every stored property
                struct Point {
                    var x = 0
                }
                """
            }
        }
    }
#endif
