//
//  ReducerConfiguration+Shared.swift
//  Exhaust
//

// MARK: - Probe Wrapper

/// Wraps one reduction probe's property invocation, receiving the candidate sequence that probe is testing.
///
/// The reducer drives the property at candidates its host never produced, so a host that wants to observe each invocation (mark it in flight, time it, log it) cannot identify the probe from outside; the sequence is how the wrapper knows which one it is around.
package typealias ProbeWrapper = @Sendable (ChoiceSequence, () -> Bool) -> Bool
