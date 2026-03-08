// Extracts a child value from a Mirror by label.
//
// Runtime support for the `#gen` macro's backward mapping. Not intended for direct use.
import ExhaustCore

@inline(__always)
public func _mirrorExtract(_ value: Any, label: String) -> Any {
    Mirror(reflecting: value).children.first(where: { $0.label == label })!.value
}

/// Extracts multiple child values from a Mirror by labels, returning them as `[Any]`.
///
/// Runtime support for the `#gen` macro's multi-generator backward mapping.
/// The labels must be in the order matching the generator/tuple parameter order.
/// Not intended for direct use.
@inline(__always)
public func _mirrorExtractAll(_ value: Any, labels: [String]) -> [Any] {
    let mirror = Mirror(reflecting: value)
    return labels.map { label in
        mirror.children.first(where: { $0.label == label })!.value
    }
}
