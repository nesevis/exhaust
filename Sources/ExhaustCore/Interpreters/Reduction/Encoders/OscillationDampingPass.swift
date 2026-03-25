//
//  OscillationDampingPass.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

/// Breaks coupled-coordinate oscillation by detecting slow convergence patterns and proposing joint moves.
///
/// When two or more coordinates are coupled by the property, per-coordinate binary search moves each by O(1) per cycle, requiring O(n) cycles to converge. This encoder detects the pattern by comparing convergence bounds between cycles: coordinates that moved by a small delta but have a large remaining distance are oscillation suspects. Suspects moving in the same direction are grouped, and a joint binary search via ``FindIntegerStepper`` shifts all coordinates in the group toward their targets by the same delta simultaneously, converging in O(log n) probes.
///
/// Conforms to ``ReductionPass`` — this is a closed-form analytical reduction, not an iterative feedback-driven encoder. It runs once per cycle after value minimization settles and uses ``ReductionPass/decode(candidate:gen:fallbackTree:property:)`` for the shared dec component.
public struct OscillationDampingPass: ReductionPass {
  public let name: EncoderName = .oscillationDamping

  // MARK: - Cross-Cycle State

  /// Convergence bounds from the previous cycle. Compared against current bounds to detect oscillation. After a structural change, coordinate indices shift and the intersection with current origins shrinks naturally, suppressing false detection without an explicit flag.
  private var previousOrigins: [Int: ConvergedOrigin]?

  // MARK: - Detection Thresholds

  /// Maximum per-cycle delta to classify as oscillating.
  private let maxVelocity: UInt64 = 4

  /// Minimum ratio of remaining distance to delta to classify as oscillating.
  private let minRemainingMultiple: UInt64 = 16

  // MARK: - Encode

  /// Detects oscillating coordinate groups and proposes joint moves.
  ///
  /// - Parameters:
  ///   - gen: The generator to materialize through.
  ///   - sequence: The current choice sequence.
  ///   - tree: The current choice tree.
  ///   - currentOrigins: Convergence bounds from this cycle's fibre descent.
  ///   - fallbackTree: Fallback tree for guided materialization.
  ///   - property: The property predicate.
  ///   - budget: Remaining materialization budget (decremented on each probe).
  /// - Returns: An improved result, or `nil` if no oscillation detected or damping unsuccessful.
  public mutating func encode<Output>(
    gen: ReflectiveGenerator<Output>,
    sequence: ChoiceSequence,
    tree: ChoiceTree,
    currentOrigins: [Int: ConvergedOrigin]?,
    fallbackTree: ChoiceTree?,
    property: (Output) -> Bool,
    budget: inout Int
  ) throws -> ReductionPassResult<Output>? {
    defer { previousOrigins = currentOrigins }

    // No comparison possible on first cycle.
    guard let previous = previousOrigins,
          let current = currentOrigins,
          previous.isEmpty == false,
          current.isEmpty == false
    else {
      return nil
    }

    // Detect oscillating coordinates.
    var suspects: [Suspect] = []
    for (index, currentOrigin) in current {
      guard let previousOrigin = previous[index] else { continue }
      guard index < sequence.count,
            let value = sequence[index].value
      else { continue }

      let currentBound = currentOrigin.bound
      let previousBound = previousOrigin.bound
      guard currentBound != previousBound else { continue }

      let targetBitPattern = value.choice.reductionTarget(
        in: value.isRangeExplicit ? value.validRange : nil
      )
      guard currentBound != targetBitPattern else { continue }

      // Compute delta and remaining distance in bit-pattern space.
      let delta = absDiff(currentBound, previousBound)
      guard delta <= maxVelocity, delta > 0 else { continue }

      // Only flag coordinates that moved TOWARD the target.
      let previousRemaining = absDiff(previousBound, targetBitPattern)
      let remaining = absDiff(currentBound, targetBitPattern)
      guard remaining < previousRemaining else { continue }

      guard remaining > delta * minRemainingMultiple else { continue }

      // Determine direction: is the target above or below the current bound?
      let movesUpward = targetBitPattern > currentBound

      suspects.append(Suspect(
        index: index,
        currentBound: currentBound,
        targetBitPattern: targetBitPattern,
        remaining: remaining,
        movesUpward: movesUpward,
        tag: value.choice.tag,
        validRange: value.validRange,
        isRangeExplicit: value.isRangeExplicit
      ))
    }

    // Group suspects by direction.
    let upward = suspects.filter(\.movesUpward)
    let downward = suspects.filter { $0.movesUpward == false }

    var bestResult: ReductionPassResult<Output>?

    for group in [downward, upward] where group.count >= 2 {
      if let result = try searchGroup(
        group,
        gen: gen,
        sequence: bestResult?.sequence ?? sequence,
        tree: bestResult?.tree ?? tree,
        fallbackTree: fallbackTree,
        property: property,
        budget: &budget
      ) {
        bestResult = result
      }
    }

    return bestResult
  }

  // MARK: - Joint Binary Search

  /// Runs a joint binary search over a group of oscillating coordinates, shifting all by the same bit-pattern delta toward their targets via ``FindIntegerStepper``.
  private func searchGroup<Output>(
    _ group: [Suspect],
    gen: ReflectiveGenerator<Output>,
    sequence: ChoiceSequence,
    tree: ChoiceTree,
    fallbackTree: ChoiceTree?,
    property: (Output) -> Bool,
    budget: inout Int
  ) throws -> ReductionPassResult<Output>? {
    let maxDelta = group.map(\.remaining).min() ?? 0
    guard maxDelta > 0 else { return nil }

    var stepper = FindIntegerStepper()
    var bestResult: ReductionPassResult<Output>?
    var k = stepper.start()

    while budget > 0 {
      let delta = UInt64(k)
      if delta > maxDelta {
        // Stepper exceeded the search range. Treat as rejection.
        guard let next = stepper.advance(lastAccepted: false) else { break }
        k = next
        continue
      }

      if let candidate = buildCandidate(
        group: group,
        delta: delta,
        sequence: bestResult?.sequence ?? sequence
      ) {
        budget -= 1
        if let result = Self.decode(
          candidate: candidate,
          gen: gen,
          fallbackTree: fallbackTree ?? (bestResult?.tree ?? tree),
          property: property
        ) {
          if result.sequence.shortLexPrecedes(bestResult?.sequence ?? sequence) {
            bestResult = result
            guard let next = stepper.advance(lastAccepted: true) else { break }
            k = next
            continue
          }
        }
      }

      guard let next = stepper.advance(lastAccepted: false) else { break }
      k = next
    }

    return bestResult
  }

  // MARK: - Candidate Construction

  /// Builds a candidate sequence by shifting all grouped coordinates toward their targets by `delta` bit-pattern units, clamped to each coordinate's remaining distance. Returns `nil` if any shifted value is invalid or the candidate is not shortlex-smaller.
  private func buildCandidate(
    group: [Suspect],
    delta: UInt64,
    sequence: ChoiceSequence
  ) -> ChoiceSequence? {
    var candidate = sequence

    for suspect in group {
      let clampedDelta = min(delta, suspect.remaining)
      let newBitPattern: UInt64
      if suspect.movesUpward {
        newBitPattern = suspect.currentBound + clampedDelta
      } else {
        newBitPattern = suspect.currentBound - clampedDelta
      }

      let newChoice = ChoiceValue(
        suspect.tag.makeConvertible(bitPattern64: newBitPattern),
        tag: suspect.tag
      )

      // Validate: finite, in range.
      if case let .floating(floatValue, _, _) = newChoice {
        guard floatValue.isFinite else { return nil }
      }
      if suspect.isRangeExplicit {
        guard newChoice.fits(in: suspect.validRange) else { return nil }
      }

      guard case .value = candidate[suspect.index] else { return nil }
      guard let value = candidate[suspect.index].value else { return nil }
      candidate[suspect.index] = .value(.init(
        choice: newChoice,
        validRange: value.validRange,
        isRangeExplicit: value.isRangeExplicit
      ))
    }

    guard candidate.shortLexPrecedes(sequence) else { return nil }
    return candidate
  }

  // MARK: - Internal Types

  private struct Suspect {
    let index: Int
    let currentBound: UInt64
    let targetBitPattern: UInt64
    let remaining: UInt64
    let movesUpward: Bool
    let tag: TypeTag
    let validRange: ClosedRange<UInt64>?
    let isRangeExplicit: Bool
  }
}

// MARK: - Helpers

private func absDiff(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
  lhs >= rhs ? (lhs - rhs) : (rhs - lhs)
}
