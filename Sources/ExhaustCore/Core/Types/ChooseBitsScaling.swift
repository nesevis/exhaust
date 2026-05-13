//
//  ChooseBitsScaling.swift
//  Exhaust
//

/// Size-scaling strategy attached to a ``ReflectiveOperation/chooseBits(min:max:tag:isRangeExplicit:scaling:)`` operation.
///
/// Sampling interpreters consult the current generation size when a chooseBits carries a non-nil scaling, narrowing the effective sampling range relative to the declared `(min, max)` range. Reflection, analysis, and tree construction ignore the scaling field — the declared range remains the single source of truth for what values are permitted.
///
/// - Note: A `nil` scaling on ``ReflectiveOperation/chooseBits(min:max:tag:isRangeExplicit:scaling:)`` means the full declared range is sampled uniformly at every size (the `.constant` case from ``SizeScaling``).
public enum ChooseBitsScaling: Sendable, Hashable {
    /// Linear interpolation from the origin toward both declared bounds as size grows.
    ///
    /// When `originBits` is `nil`, the origin is resolved at sample time to the tag's ``TypeTag/simplestBitPattern`` clamped into the declared range.
    case linear(originBits: UInt64?)

    /// Exponential interpolation from the origin toward both declared bounds as size grows.
    ///
    /// When `originBits` is `nil`, the origin is resolved at sample time to the tag's ``TypeTag/simplestBitPattern`` clamped into the declared range.
    case exponential(originBits: UInt64?)
}
