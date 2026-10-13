//
//  GraphEncoder+Shared.swift
//  Exhaust
//

// MARK: - Encoder Probe

/// The mutation a probe would enact if accepted, returned by ``GraphEncoder/nextProbe(into:lastAccepted:)``.
///
/// The candidate sequence itself is written into the caller-owned `inout` buffer to avoid per-probe COW allocation. The mutation carries everything the graph needs to update itself in place; for value-only encoders it is a ``ProjectedMutation/leafValues(_:)`` listing the changed leaves with their bind-inner reshape markers.
///
/// - SeeAlso: ``ProjectedMutation``, ``LeafChange``, ``ChoiceGraph/apply(_:)``
typealias EncoderProbe = ProjectedMutation
