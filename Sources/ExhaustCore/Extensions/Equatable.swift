//
//  Equatable.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/7/2025.
//

/// https://nilcoalescing.com/blog/CheckIfTwoValuesOfTypeAnyAreEqual/
package extension Equatable {
    /// Performs type-erased equality by attempting a two-phase cast (direct, then reverse) to handle cases where existential wrapping erases the concrete type on one side but not the other.
    func isEqual(_ other: any Equatable) -> Bool {
        guard let other = other as? Self else {
            return other.isExactlyEqual(self)
        }
        return self == other
    }

    private func isExactlyEqual(_ other: any Equatable) -> Bool {
        guard let other = other as? Self else {
            return false
        }
        return self == other
    }

    /// Returns false for non-`Equatable` values, providing a safe fallback for heterogeneous comparison without requiring the caller to check conformance.
    func isEqualToAny(_ other: Any) -> Bool {
        guard let other = other as? any Equatable else {
            return false
        }
        return isEqual(other)
    }
}

private protocol _OptionalProtocol {
    var _unwrapped: Any? { get }
}

extension Optional: _OptionalProtocol {
    var _unwrapped: Any? {
        map { $0 as Any }
    }
}

/// Returns whether the value is a boxed `Optional` in its `.none` case.
private func isNilOptional(_ value: Any) -> Bool {
    guard let optional = value as? _OptionalProtocol else {
        return false
    }
    return optional._unwrapped == nil
}

/// Unwraps an `Any` value that may contain a boxed `Optional`, returning the inner value or the original if it is not optional.
private func unwrapOptional(_ value: Any) -> Any {
    guard let optional = value as? _OptionalProtocol,
          let inner = optional._unwrapped
    else {
        return value
    }
    return inner
}

/// Recursive structural equality for values that may not conform to `Equatable` (for example, tuples). Uses `Equatable/isEqualToAny(_:)` at leaf nodes and `Mirror` to decompose compound values like tuples. Returns `true` when both values are structurally identical down to their `Equatable` leaves.
package func structurallyEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    // Two nils are equal by value regardless of their wrapped types; a nil against anything else, including `.some(nil)`, is not. Decided before unwrapping because unwrapping first collapses `nil` and `.some(nil)` into the same shape, and because nils carry no Mirror children, so the childless-values guard at the bottom would otherwise reject the equal pair.
    let lhsIsNil = isNilOptional(lhs)
    let rhsIsNil = isNilOptional(rhs)
    if lhsIsNil || rhsIsNil {
        return lhsIsNil == rhsIsNil
    }

    // Peel one `.some` layer and re-enter so the nil check above applies at every nesting level; without re-entry, `.some(nil)` on both sides falls through to the childless-values guard and compares unequal. Peeling one side alone keeps the existing tolerance for incidental one-sided `Any` boxing.
    if lhs is _OptionalProtocol || rhs is _OptionalProtocol {
        return structurallyEqual(unwrapOptional(lhs), unwrapOptional(rhs))
    }

    if let equatable = lhs as? any Equatable {
        return equatable.isEqualToAny(rhs)
    }

    let lhsMirror = Mirror(reflecting: lhs)
    let rhsMirror = Mirror(reflecting: rhs)

    guard lhsMirror.displayStyle == rhsMirror.displayStyle,
          lhsMirror.children.count == rhsMirror.children.count
    else {
        return false
    }

    for (lhsChild, rhsChild) in zip(lhsMirror.children, rhsMirror.children) {
        // swiftlint:disable:next for_where
        if structurallyEqual(lhsChild.value, rhsChild.value) == false {
            return false
        }
    }

    return lhsMirror.children.isEmpty == false
}
