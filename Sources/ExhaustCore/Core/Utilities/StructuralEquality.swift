// MARK: - Structural Equality

/// Compares type-erased values, including values that do not conform to `Equatable`, and inspects boxed optionals.
package enum StructuralEquality {
    /// Returns whether the value is a boxed `Optional` in its `.none` case.
    ///
    /// Only the outermost layer is inspected: a boxed `.some(nil)` is not nil. Backtrack auditions rely on that distinction, since an arm of type `Output?` where `Output` is itself optional legitimately produces `.some(nil)`.
    package static func isNilOptional(_ value: Any) -> Bool {
        guard let optional = value as? _OptionalProtocol else {
            return false
        }
        return optional._unwrapped == nil
    }

    /// Unwraps an `Any` value that may contain a boxed `Optional`, returning the inner value or the original if it is not optional.
    package static func unwrapOptional(_ value: Any) -> Any {
        guard let optional = value as? _OptionalProtocol,
              let inner = optional._unwrapped
        else {
            return value
        }
        return inner
    }

    /// Recursive structural equality for values that may not conform to `Equatable` (for example, tuples). Uses `Equatable/isEqualToAny(_:)` at leaf nodes and `Mirror` to decompose compound values like tuples. Returns `true` when both values are structurally identical down to their `Equatable` leaves.
    ///
    /// Values of different dynamic types are never equal, and enum cases are distinguished by name as well as by payload, so two cases carrying the same associated-value shape never compare equal. Values that decompose to no children reach the childless-value rule at the bottom of this file, which the child walk cannot decide.
    package static func structurallyEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        // Two nils are equal by value regardless of their wrapped types; a nil against anything else, including `.some(nil)`, is not. Decided before unwrapping because unwrapping first collapses `nil` and `.some(nil)` into the same shape, and because nils carry no Mirror children, so the childless-values guard at the bottom would otherwise reject the equal pair.
        let lhsIsNil = StructuralEquality.isNilOptional(lhs)
        let rhsIsNil = StructuralEquality.isNilOptional(rhs)
        if lhsIsNil || rhsIsNil {
            return lhsIsNil == rhsIsNil
        }

        // Peel one `.some` layer and re-enter so the nil check above applies at every nesting level; without re-entry, `.some(nil)` on both sides falls through to the childless-values guard and compares unequal. Peeling one side alone keeps the existing tolerance for incidental one-sided `Any` boxing.
        if lhs is _OptionalProtocol || rhs is _OptionalProtocol {
            return StructuralEquality.structurallyEqual(StructuralEquality.unwrapOptional(lhs), StructuralEquality.unwrapOptional(rhs))
        }

        if let equatable = lhs as? any Equatable {
            return equatable.isEqualToAny(rhs)
        }

        guard type(of: lhs) == type(of: rhs) else {
            return false
        }

        let lhsMirror = Mirror(reflecting: lhs)
        let rhsMirror = Mirror(reflecting: rhs)

        guard lhsMirror.children.count == rhsMirror.children.count else {
            return false
        }

        // An enum carries its case identity in its single child's label: `.delete(key: 0)` and `.getOrElse(key: 0)` both mirror to one `Int` child, so comparing values alone reports two different cases as equal. Every other display style's labels are field names or nil, which the shared dynamic type already fixes.
        for (lhsChild, rhsChild) in zip(lhsMirror.children, rhsMirror.children) {
            guard lhsChild.label == rhsChild.label,
                  StructuralEquality.structurallyEqual(lhsChild.value, rhsChild.value)
            else {
                return false
            }
        }

        guard lhsMirror.children.isEmpty else {
            return true
        }
        return childlessValuesEqual(lhs, rhs, displayStyle: lhsMirror.displayStyle)
    }

    /// Decides equality for two values of one dynamic type that decompose to no children, where the child walk has nothing to compare. The caller has already established that both values share a dynamic type.
    ///
    /// A payload-free enum case carries its identity in the case name alone, and `String(describing:)` is the only handle Swift offers on it. Without this rule such a case compares unequal to itself, and a linearizability check reading command responses fabricates a response mismatch out of a correct run. A struct with no stored properties, the empty tuple, and an empty collection hold no state, so two values of one such type are equal by construction.
    ///
    /// Everything else stays `false`, because nothing observable separates "equal" from "cannot tell" — a class instance whose storage the mirror does not expose being the case that matters.
    ///
    /// - Note: A non-`Equatable` enum whose custom `description` renders two cases identically compares them equal. Conforming the type to `Equatable` takes the exact path instead.
    private static func childlessValuesEqual(_ lhs: Any, _ rhs: Any, displayStyle: Mirror.DisplayStyle?) -> Bool {
        switch displayStyle {
            case .enum:
                return String(describing: lhs) == String(describing: rhs)
            case .struct, .tuple, .collection, .set, .dictionary:
                return true
            default:
                return false
        }
    }
}

// MARK: - Optional Inspection

private protocol _OptionalProtocol {
    var _unwrapped: Any? { get }
}

extension Optional: _OptionalProtocol {
    var _unwrapped: Any? {
        map { $0 as Any }
    }
}
