// MARK: - Regime Probe Encoder

/// Emits a single probe with all values set to their semantic simplest form.
///
/// Used to detect whether a property failure is structural (elimination regime) or
/// value-sensitive. If the all-zeroed probe still fails, the failure is structural —
/// no value assignment can improve on it, and PRNG retries are waste. If it passes,
/// specific values are required to reproduce the failure.
///
/// Sits between the guided and PRNG tiers in a ``MorphismDescriptor`` dominance chain.
/// When the probe succeeds (property fails on the all-zeroed sequence), it dominates
/// the PRNG tier and prevents unnecessary retries.
struct RegimeProbeEncoder: ComposableEncoder {
    let name: EncoderName = .productSpaceBatch
    let phase = ReductionPhase.valueMinimization

    private var probe: ChoiceSequence?
    private var emitted = false

    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        emitted = false
        var candidate = sequence
        var needsRun = false
        var index = 0
        while index < candidate.count {
            if let value = candidate[index].value {
                let target = ZeroValueEncoder.simplestTarget(for: value)
                if target != value.choice {
                    needsRun = true
                    candidate[index] = .value(.init(
                        choice: target,
                        validRange: value.validRange,
                        isRangeExplicit: value.isRangeExplicit
                    ))
                }
            }
            index += 1
        }
        probe = needsRun ? candidate : nil
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard emitted == false, let candidate = probe else { return nil }
        emitted = true
        return candidate
    }
}
