/// Controls recursive and structural growth in an `@Exhaustable`-derived generator.
///
/// | Preset | Recursion | Nodes |
/// | --- | ---: | ---: |
/// | `.quick` | 10 | 50 |
/// | `.standard` | 20 | 100 |
/// | `.thorough` | 40 | 200 |
/// | `.extensive` | 80 | 400 |
///
/// Recursive fuel is divided among payload edges that participate in a type cycle. The node ceiling counts the complete generated structure, including annotated values, standard containers, and opaque payloads.
///
/// Use `.standard` unless generation needs systematically smaller or larger values. Use ``custom(recursion:nodes:)`` when a type needs independently chosen limits.
public enum ExhaustableBudget: Sendable {
    /// Generates smaller recursive and container structures than the default.
    case quick

    /// Generates structures suitable for most derived property-test inputs.
    case standard

    /// Generates larger structures for properties that need deeper or wider examples.
    case thorough

    /// Generates the largest preset structures at a correspondingly higher construction and execution cost.
    case extensive

    /// Supplies explicit recursive fuel and a structural node ceiling.
    ///
    /// - Parameters:
    ///   - recursion: The fuel divided among recursive edges. Must be nonnegative.
    ///   - nodes: The maximum structural node count at size 100. Must be positive.
    case custom(recursion: Int, nodes: Int)

    /// Returns the recursive fuel available at size 100.
    public var recursion: Int {
        switch self {
            case .quick:
                10
            case .standard:
                20
            case .thorough:
                40
            case .extensive:
                80
            case let .custom(recursion, _):
                recursion
        }
    }

    /// Returns the structural node ceiling available at size 100.
    public var nodes: Int {
        switch self {
            case .quick:
                50
            case .standard:
                100
            case .thorough:
                200
            case .extensive:
                400
            case let .custom(_, nodes):
                nodes
        }
    }

    /// Scales both recursive fuel and the node ceiling by a positive multiplier.
    public static func * (lhs: ExhaustableBudget, rhs: Int) -> ExhaustableBudget {
        precondition(rhs > 0, "Multiplier must be positive")
        return .custom(
            recursion: lhs.recursion * rhs,
            nodes: lhs.nodes * rhs
        )
    }

    /// Scales both recursive fuel and the node ceiling by a positive multiplier.
    public static func * (lhs: Int, rhs: ExhaustableBudget) -> ExhaustableBudget {
        rhs * lhs
    }

    /// Divides recursive fuel and the node ceiling by a positive divisor.
    public static func / (lhs: ExhaustableBudget, rhs: Int) -> ExhaustableBudget {
        precondition(rhs > 0, "Divisor must be positive")
        return .custom(
            recursion: lhs.recursion / rhs,
            nodes: max(1, lhs.nodes / rhs)
        )
    }
}

/// Configures an `@Exhaustable` declaration or a root derived-generator request.
public enum ExhaustableSettings: Sendable {
    /// Selects recursive fuel and the complete structural node ceiling. Defaults to ``ExhaustableBudget/standard``.
    case budget(ExhaustableBudget)

    /// Selects the sampled domains of automatically generated payloads. Defaults to ``ExhaustableDomain/full``.
    case domain(ExhaustableDomain)
}

/// Resolves variadic settings with the last occurrence of each setting taking precedence.
package struct ResolvedExhaustableSettings: Sendable {
    package let budget: ExhaustableBudget
    package let domain: ExhaustableDomain

    package init(
        _ settings: [ExhaustableSettings],
        budget defaultBudget: ExhaustableBudget = .standard,
        domain defaultDomain: ExhaustableDomain = .full
    ) {
        var budget = defaultBudget
        var domain = defaultDomain
        for setting in settings {
            switch setting {
                case let .budget(value):
                    budget = value
                case let .domain(value):
                    domain = value
            }
        }
        self.budget = budget
        self.domain = domain
    }
}
