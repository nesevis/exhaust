//
//  PrecomputedComposableEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/3/2026.
//

/// Wraps a pre-built array of candidate sequences as a ``ComposableEncoder``.
///
/// The ``start(sequence:tree:positionRange:context:)`` method resets the iteration index. ``nextProbe(lastAccepted:)`` yields candidates in order. Feedback is ignored — each candidate is independent.
struct PrecomputedComposableEncoder: ComposableEncoder {
  let name: EncoderName
  let phase: ReductionPhase
  let candidates: [ChoiceSequence]

  private var index = 0

  init(
    name: EncoderName,
    phase: ReductionPhase,
    candidates: [ChoiceSequence]
  ) {
    self.name = name
    self.phase = phase
    self.candidates = candidates
  }

  mutating func start(
    sequence _: ChoiceSequence,
    tree _: ChoiceTree,
    positionRange _: ClosedRange<Int>,
    context _: ReductionContext
  ) {
    index = 0
  }

  mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
    guard index < candidates.count else { return nil }
    let candidate = candidates[index]
    index += 1
    return candidate
  }
}
