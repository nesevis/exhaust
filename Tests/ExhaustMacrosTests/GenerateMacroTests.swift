#if os(macOS)
    import MacroTesting
    import Testing
    @testable import ExhaustMacros

    @Suite(
        "GenerateMacro expansion tests",
        .macros(["gen": GenerateMacro.self], record: .failed)
    )
    struct GenerateMacroTests {
        @Test("Single generator with struct init produces _macroMap bidirectional")
        func singleGeneratorBidirectional() {
            assertMacro {
                """
                #gen(nameGen) { name in
                    Person(name: name)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMap(nameGen, label: "name", forward: { name in
                    Person(name: name)
                    })
                """
            }
        }

        @Test("Two generators with struct init produces _macroZip")
        func twoGeneratorsBidirectional() {
            assertMacro {
                """
                #gen(nameGen, ageGen) { name, age in
                    Person(name: name, age: age)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroZip(nameGen, ageGen, labels: ["name", "age"], forward: { name, age in
                    Person(name: name, age: age)
                    })
                """
            }
        }

        @Test("Reordered arguments produce correctly ordered backward labels")
        func reorderedArguments() {
            assertMacro {
                """
                #gen(ageGen, nameGen) { age, name in
                    Person(name: name, age: age)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroZip(ageGen, nameGen, labels: ["age", "name"], forward: { age, name in
                    Person(name: name, age: age)
                    })
                """
            }
        }

        @Test("Shorthand parameters with non-init body produce forward-only")
        func shorthandParametersFallback() {
            assertMacro {
                """
                #gen(intGen) { $0 * 2 }
                """
            } expansion: {
                """
                intGen.map {
                    $0 * 2
                }
                """
            }
        }

        @Test("Single generator with shorthand parameter produces bidirectional")
        func singleGeneratorShorthandBidirectional() {
            assertMacro {
                """
                #gen(nameGen) { Person(name: $0) }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMap(nameGen, label: "name", forward: {
                        Person(name: $0)
                    })
                """
            }
        }

        @Test("Two generators with shorthand parameters produce bidirectional")
        func twoGeneratorsShorthandBidirectional() {
            assertMacro {
                """
                #gen(nameGen, ageGen) { Person(name: $0, age: $1) }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroZip(nameGen, ageGen, labels: ["name", "age"], forward: {
                        Person(name: $0, age: $1)
                    })
                """
            }
        }

        @Test("Shorthand parameters with reordered indices produce correct backward labels")
        func shorthandReorderedIndices() {
            assertMacro {
                """
                #gen(ageGen, nameGen) { Person(name: $1, age: $0) }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroZip(ageGen, nameGen, labels: ["age", "name"], forward: {
                        Person(name: $1, age: $0)
                    })
                """
            }
        }

        @Test("Complex argument expressions produce forward-only")
        func complexExpressionFallback() {
            assertMacro {
                """
                #gen(nameGen) { name in
                    Person(name: name.uppercased())
                }
                """
            } expansion: {
                """
                nameGen.map { name in
                    Person(name: name.uppercased())
                }
                """
            }
        }

        @Test("Multi-statement closure produces forward-only")
        func multiStatementFallback() {
            assertMacro {
                """
                #gen(intGen) { x in
                    let doubled = x * 2
                    return doubled
                }
                """
            } expansion: {
                """
                intGen.map { x in
                    let doubled = x * 2
                    return doubled
                }
                """
            }
        }

        @Test("Single generator without closure passes through")
        func singleGeneratorPassthrough() {
            assertMacro {
                """
                #gen(intGen)
                """
            } expansion: {
                """
                intGen
                """
            }
        }

        @Test("Implicit member chain gets Generator prefix in expansion")
        func implicitMemberChainResolution() {
            assertMacro {
                """
                #gen(.int16().array(length: 0...10))
                """
            } expansion: {
                """
                .int16().array(length: 0 ... 10)
                """
            }
        }

        @Test("Multiple generators without closure produce zip")
        func multipleGeneratorsZip() {
            assertMacro {
                """
                #gen(intGen, stringGen)
                """
            } expansion: {
                """
                __ExhaustRuntime.__zip(intGen, stringGen)
                """
            }
        }

        @Test("Three generators with struct init")
        func threeGeneratorsBidirectional() {
            assertMacro {
                """
                #gen(nameGen, ageGen, emailGen) { name, age, email in
                    User(name: name, age: age, email: email)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroZip(nameGen, ageGen, emailGen, labels: ["name", "age", "email"], forward: { name, age, email in
                    User(name: name, age: age, email: email)
                    })
                """
            }
        }

        @Test("Single generator with return statement produces _macroMap bidirectional")
        func singleGeneratorWithReturn() {
            assertMacro {
                """
                #gen(nameGen) { name in
                    return Person(name: name)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMap(nameGen, label: "name", forward: { name in
                    return Person(name: name)
                    })
                """
            }
        }

        @Test("Unlabeled arguments produce bidirectional with positional Mirror labels")
        func unlabeledArgumentsBidirectional() {
            assertMacro {
                """
                #gen(intGen) { x in
                    Wrapper(x)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMapScalar(intGen, forward: { x in
                    Wrapper(x)
                    })
                """
            }
        }

        @Test("Two unlabeled arguments produce bidirectional with positional Mirror labels")
        func twoUnlabeledArgumentsBidirectional() {
            assertMacro {
                """
                #gen(intGen, strGen) { x, y in
                    Pair(x, y)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime.__zip(intGen, strGen).map { x, y in
                    Pair(x, y)
                }
                """
            }
        }

        @Test("Shorthand parameters with unlabeled arguments produce bidirectional")
        func shorthandUnlabeledBidirectional() {
            assertMacro {
                """
                #gen(intGen) { Wrapper($0) }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMapScalar(intGen, forward: {
                        Wrapper($0)
                    })
                """
            }
        }

        // MARK: - Enum case pattern-matching backward

        @Test("Single-value enum case produces pattern-matching backward")
        func singleEnumCaseBidirectional() {
            assertMacro {
                """
                #gen(intGen) { age in
                    Pet.cat(age)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMap(intGen, backward: {
                        guard case let .cat(v0) = $0 else {
                            return nil
                        };
                        return v0
                    }, forward: { age in
                    Pet.cat(age)
                    })
                """
            }
        }

        @Test("Multi-value enum case produces pattern-matching backward")
        func multiEnumCaseBidirectional() {
            assertMacro {
                """
                #gen(intGen, strGen) { age, name in
                    Pet.dog(age, name)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroZip(intGen, strGen, backward: {
                        guard case let .dog(v0, v1) = $0 else {
                            return nil
                        };
                        return [v0 as Any, v1 as Any]
                    }, forward: { age, name in
                    Pet.dog(age, name)
                    })
                """
            }
        }

        @Test("Labeled enum case produces labeled pattern bindings")
        func labeledEnumCaseBidirectional() {
            assertMacro {
                """
                #gen(intGen) { age in
                    Pet.cat(age: age)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMap(intGen, backward: {
                        guard case let .cat(age: v0) = $0 else {
                            return nil
                        };
                        return v0
                    }, forward: { age in
                    Pet.cat(age: age)
                    })
                """
            }
        }

        @Test("Shorthand enum case produces pattern-matching backward")
        func shorthandEnumCaseBidirectional() {
            assertMacro {
                """
                #gen(intGen) { Pet.cat($0) }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMap(intGen, backward: {
                        guard case let .cat(v0) = $0 else {
                            return nil
                        };
                        return v0
                    }, forward: {
                        Pet.cat($0)
                    })
                """
            }
        }

        @Test("Qualified type initializer produces Mirror-based backward, not enum case")
        func qualifiedTypeInitializerUsesMirror() {
            assertMacro {
                """
                #gen(majorGen, minorGen) { major, minor in
                    ABI.VersionNumber(major: major, minor: minor)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroZip(majorGen, minorGen, labels: ["major", "minor"], forward: { major, minor in
                    ABI.VersionNumber(major: major, minor: minor)
                    })
                """
            }
        }

        @Test("Shorthand qualified type initializer produces Mirror-based backward")
        func shorthandQualifiedTypeInitializerUsesMirror() {
            assertMacro {
                """
                #gen(majorGen) { ABI.VersionNumber(major: $0) }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMap(majorGen, label: "major", forward: {
                        ABI.VersionNumber(major: $0)
                    })
                """
            }
        }

        @Test("Implicit member with uppercase name produces Mirror-based backward")
        func implicitMemberUppercaseUsesMirror() {
            assertMacro {
                """
                #gen(majorGen) { .VersionNumber(major: $0) }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMap(majorGen, label: "major", forward: {
                        .VersionNumber(major: $0)
                    })
                """
            }
        }

        @Test("Deeply qualified enum case with lowercase member produces pattern-matching backward")
        func deeplyQualifiedEnumCase() {
            assertMacro {
                """
                #gen(intGen) { x in
                    Foo.Bar.baz(x)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMap(intGen, backward: {
                        guard case let .baz(v0) = $0 else {
                            return nil
                        };
                        return v0
                    }, forward: { x in
                    Foo.Bar.baz(x)
                    })
                """
            }
        }

        @Test("Explicit .init on qualified type produces Mirror-based backward")
        func qualifiedExplicitInitUsesMirror() {
            assertMacro {
                """
                #gen(majorGen) { major in
                    ABI.VersionNumber.init(major: major)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroMap(majorGen, label: "major", forward: { major in
                    ABI.VersionNumber.init(major: major)
                    })
                """
            }
        }

        @Test("Reordered enum case parameters produce correctly ordered backward")
        func reorderedEnumCaseBidirectional() {
            assertMacro {
                """
                #gen(nameGen, ageGen) { name, age in
                    Pet.dog(age, name)
                }
                """
            } expansion: {
                """
                __ExhaustRuntime._macroZip(nameGen, ageGen, backward: {
                        guard case let .dog(v0, v1) = $0 else {
                            return nil
                        };
                        return [v1 as Any, v0 as Any]
                    }, forward: { name, age in
                    Pet.dog(age, name)
                    })
                """
            }
        }
    }
#endif
