/// Namespaces the metadata and conformance emitted by ``Exhaustable(maximumDepth:maximumNodes:stateSpace:)``.
///
/// These declarations are public only because macro expansions in application modules must name them. They are implementation infrastructure, not user conformance or customization points. The namespace has no dependency on ExhaustCore, so an annotated application type does not link generator or interpreter code.
public enum __Exhaustable { // swiftlint:disable:this type_name
    /// Supplies construction metadata for an annotated type.
    ///
    /// Apply `@Exhaustable` rather than conforming manually. Importing `ExhaustGenerators` or `Exhaust` then exposes the annotated type's `gen(...)` factory.
    public protocol Conformance {
        /// Describes the type's constructors in declaration order.
        static var __generatorDescriptor: TypeDescriptor<Self> { get }
    }

    /// Describes the constructors of an annotated type. An enum has one constructor per case; a struct or final class has one constructor whose payload is its stored properties.
    public struct TypeDescriptor<Value>: Sendable {
        /// Lists constructors in declaration order.
        public let constructors: [ConstructorDescriptor<Value>]

        /// Bounds nesting through annotated payloads when the declaration specifies a ceiling; `nil` leaves the choice to the derivation.
        public let maximumDepth: Int?

        /// Caps structural nodes when specified. Each annotated value, standard container, and opaque payload costs one node; descendants consume the remainder.
        public let maximumNodes: Int?

        /// Caps inherited numeric domains; `.full` leaves the parent's state space unchanged.
        public let stateSpace: GeneratorStateSpace

        /// Identifies the declaration's source file without an absolute checkout path.
        public let fileID: StaticString

        /// Identifies the declaration's source line for its derived generator family.
        public let line: UInt

        /// Distinguishes declarations on the same source line.
        public let column: UInt

        /// Creates metadata with a source identity shared by the type's derived generators at every depth.
        ///
        /// The macro supplies the original annotation's location explicitly. Other construction sites default to this initializer's call site. Moving that location can change the family's fingerprint; launching another process does not.
        ///
        /// - Parameters:
        ///   - constructors: The type's constructors in declaration order.
        ///   - maximumDepth: The declared nesting ceiling for this type inside itself, or `nil` to leave the choice to the derivation.
        ///   - maximumNodes: The declared structural node ceiling, or `nil` for no node ceiling.
        ///   - stateSpace: The state space this type caps its occurrences to.
        ///   - fileID: The module-qualified source file identifier, not an absolute path.
        ///   - line: The one-based source line of the declaration's annotation.
        ///   - column: The one-based source column of the declaration's annotation.
        public init(
            constructors: [ConstructorDescriptor<Value>],
            maximumDepth: Int? = nil,
            maximumNodes: Int? = nil,
            stateSpace: GeneratorStateSpace = .full,
            fileID: StaticString = #fileID,
            line: UInt = #line,
            column: UInt = #column
        ) {
            self.constructors = constructors
            self.maximumDepth = maximumDepth
            self.maximumNodes = maximumNodes
            self.stateSpace = stateSpace
            self.fileID = fileID
            self.line = line
            self.column = column
        }
    }

    /// Describes one sum-of-products constructor and the inverse operations that construct and decompose its values.
    public struct ConstructorDescriptor<Value>: Sendable {
        /// Names the enum case or product type without argument labels.
        public let name: String

        /// Lists payload types in declaration order. Empty for a payload-free enum case or product.
        public let payloadTypes: [Any.Type]

        /// Builds the constructor from payload values in declaration order. Each element must have the matching entry's type in ``payloadTypes``.
        public let embed: @Sendable ([Any]) -> Value

        /// Returns the constructor's payload values in declaration order, or `nil` when an enum value belongs to another constructor.
        public let extract: @Sendable (Value) -> [Any]?

        /// Creates a constructor descriptor for a macro expansion.
        public init(
            name: String,
            payloadTypes: [Any.Type],
            embed: @escaping @Sendable ([Any]) -> Value,
            extract: @escaping @Sendable (Value) -> [Any]?
        ) {
            self.name = name
            self.payloadTypes = payloadTypes
            self.embed = embed
            self.extract = extract
        }
    }
}

/// Derives a generator for use with the Exhaust property-testing library.
///
/// Apply this macro to an enum, struct, or final class in the application target while importing only `Exhaustable`. In a test target that imports `ExhaustGenerators` or `Exhaust`, the annotated type gains a `gen(...)` factory. Use `Term.gen()` for the annotation's defaults, or pass arguments such as `Term.gen(maximumDepth: 6, overriding: .int(in: 0 ... 9))` to customize a generator at its use site. A derived generator for another annotated type that holds a `Term` resolves that payload through this annotation, without an override.
///
/// ```swift
/// @Exhaustable
/// indirect enum Term {
///     case variable(Int)
///     case abstraction(Type, Term)
///     case application(Term, Term)
/// }
/// ```
///
/// The macro records construction metadata rather than linking the generator runtime into the application target. For an enum, the expansion lists one constructor per case, with associated-value types and closures that build and take apart the case. A struct or final class has one constructor whose payload is its stored properties in declaration order. Structs use Swift's synthesized memberwise initializer or a verified direct equivalent; final classes gain a memberwise initializer.
///
/// A recursive type nests as deeply as the derived generator's depth allows, which grows with the size parameter toward that generator's ceiling. Pass `maximumDepth:` to set a different ceiling for this type where it appears as its own payload; a shallower one keeps values small for a type whose cases branch widely, a deeper one reaches longer chains.
///
/// ```swift
/// @Exhaustable(maximumDepth: 6)
/// indirect enum Expr { ... }
/// ```
///
/// Pass `maximumNodes:` to opt into structural budget splitting. Each annotated value, standard container, and opaque payload costs one node. Products reserve their children's minimum costs and divide the remainder evenly; containers divide their remaining allowance among their elements, counting both dictionary keys and values. Empty containers still cost one node. An override is one opaque node regardless of its contents, so this does not bound memory, string length, or work inside supplied generators.
///
/// The derived generator prebuilds one layer per distinct allowance when it is created, so construction cost grows with the ceiling: roughly linearly for products, and closer to the square of the ceiling for recursive containers, which build one layer per feasible element count. Ceilings in the low hundreds are cheap; ceilings in the thousands on container-heavy types cost noticeable time and memory before the first value is generated.
///
/// ```swift
/// @Exhaustable(maximumDepth: 6, maximumNodes: 128)
/// indirect enum Tree { case children([Tree]) }
/// ```
///
/// The root allowance grows with Exhaust's size parameter toward the ceiling. A nested annotation caps that type's allocated share; it never replenishes the parent's budget. `Type.gen(maximumNodes:)` overrides the root annotation. Without a node limit on the root or its dependencies, the existing depth-only policy is unchanged.
///
/// Pass `stateSpace: .small` to favor collisions with numeric magnitudes up to 100, automatically derived sequence lengths up to 10, and 201 daily dates centered on January 1, 2026 UTC. `.tiny` uses numeric and sequence ceilings of 10 and 5, respectively, and 21 daily dates around the same midpoint. `.medium` uses numeric and sequence ceilings of 10,000 and 20 to reduce processing costs while preserving the full date domain. Sequence limits apply to arrays, sets, dictionaries, strings, and `Data`. The default, `.full`, preserves existing domains and scaling, including sequence lengths up to 100 and `Date.distantPast...Date.distantFuture` at one-minute resolution. The policy propagates through nested types and container contents; nested annotations cap it, and explicit payload overrides take precedence. Other leaf types and structural limits are unchanged. See ``GeneratorStateSpace`` for details.
///
/// Products require explicitly typed, individually named stored properties. A struct may declare one initializer whose parameters match every stored property in order, label, and type, and whose body only assigns each parameter to its corresponding property. Defaults, effects, failable initialization, and other in-body initializers are rejected. Final classes must not declare in-body initializers. A `var` may have an initial value or observers; an initialized `let` is rejected rather than silently omitted from the generated metadata or assigned twice. Computed and static properties are excluded. Property wrappers, stored-property attributes, lazy or weak/unowned storage, and conditional member blocks are not supported.
///
/// Put additional struct initializers in an extension to preserve Swift's memberwise initializer. For custom construction that does not preserve the memberwise arguments, write a generator instead and supply it through `overriding:` when deriving a containing type. A final class must have no inheritance clause: syntax alone cannot distinguish a superclass from a protocol or type alias. Put its protocol conformances in extensions, and do not declare an initializer elsewhere that duplicates the generated memberwise signature.
///
/// Generic enums, structs, final classes, and declarations nested in generic types are supported. Derive a concrete specialization, such as `Tree<Int>.gen()`. Each concrete payload must have a built-in generator, be annotated, be a supported container, or have an explicit override. Generic parameters do not need a generator protocol constraint.
///
/// ```swift
/// @Exhaustable
/// indirect enum Tree<Element> {
///     case leaf(Element)
///     case branch(Tree<Element>, Tree<Element>)
/// }
/// ```
///
/// Descriptor closures are sendable. Under strict concurrency, protocol-constrained generic parameters and associated types used by those closures may need `SendableMetatype` constraints on the original declaration. For example, use `Element: Hashable & SendableMetatype` rather than requiring `Element: Sendable`; the generated values themselves need not be sendable.
///
/// Recursive specializations must form a finite dependency graph. Exact repetitions and finite cycles that change arguments are supported. Discovery rejects more than 32 distinct specializations of the same annotation on one active dependency path, preventing types such as `Nested<Element>` containing `Nested<[Element]>` from expanding indefinitely. This conservative limit also rejects unusually deep finite chains of specializations. A depth or node ceiling does not bypass discovery; supply an exact payload override to terminate such a dependency.
///
/// Generic parameter packs and enum cases inside conditional member blocks are not supported.
///
/// - Parameters:
///   - maximumDepth: The deepest nesting of this type inside itself that a derived generator produces. Defaults to 10, which a `gen(maximumDepth:)` argument overrides.
///   - maximumNodes: An optional positive structural node ceiling. Defaults to no node ceiling.
///   - stateSpace: The state space for numeric values, default sequence lengths, and dates. Defaults to `.full`.
@attached(extension, conformances: __Exhaustable.Conformance, names: named(__generatorDescriptor))
@attached(member, names: named(init))
public macro Exhaustable(
    maximumDepth: Int? = nil,
    maximumNodes: Int? = nil,
    stateSpace: GeneratorStateSpace = .full
) = #externalMacro(module: "ExhaustMacros", type: "ExhaustableMacro")
