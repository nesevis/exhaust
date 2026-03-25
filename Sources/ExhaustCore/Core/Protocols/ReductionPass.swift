//
//  ReductionPass.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

/// A self-contained reduction morphism that bundles enc and dec in a single pass.
///
/// ``ComposableEncoder`` is purely enc — it produces candidates via ``ComposableEncoder/nextProbe(lastAccepted:)`` while the dec (materialization + property check) lives externally in `runComposable`. A ``ReductionPass`` bundles both: conformers implement type-specific `encode` methods that detect a pattern, generate candidates, and call ``decode(candidate:gen:fallbackTree:property:)`` to materialize and validate internally.
///
/// Reduction passes are analytical and few-shot — they inspect the current state, propose candidates, and accept or reject without participating in feedback loops or Kleisli composition.
public protocol ReductionPass {
  /// Typed identifier for logging and dominance tracking.
  var name: EncoderName { get }
}

// MARK: - Shared Dec Component

public extension ReductionPass {
  /// Decodes a candidate sequence by materializing it through the generator and validating the property.
  ///
  /// This is the dec component shared by all reduction passes. Returns `nil` if materialization fails or the property passes.
  ///
  /// - Parameters:
  ///   - candidate: The candidate choice sequence to decode.
  ///   - gen: The generator to materialize through.
  ///   - fallbackTree: The fallback tree for guided materialization, or `nil` for exact mode.
  ///   - property: The property predicate. Returns `true` when the property passes (no failure).
  /// - Returns: The decoded result, or `nil` if the candidate is rejected.
  static func decode<Output>(
    candidate: ChoiceSequence,
    gen: ReflectiveGenerator<Output>,
    fallbackTree: ChoiceTree?,
    property: (Output) -> Bool
  ) -> ReductionPassResult<Output>? {
    let mode: ReductionMaterializer.Mode
    if let fallbackTree {
      let seed = ZobristHash.hash(of: candidate)
      mode = .guided(seed: seed, fallbackTree: fallbackTree)
    } else {
      mode = .exact
    }

    switch ReductionMaterializer.materialize(gen, prefix: candidate, mode: mode) {
    case let .success(output, freshTree, _):
      guard property(output) == false else { return nil }
      return ReductionPassResult(
        sequence: ChoiceSequence(freshTree),
        tree: freshTree,
        output: output
      )
    case .rejected, .failed:
      return nil
    }
  }
}

/// Result of a successful reduction pass.
public struct ReductionPassResult<Output> {
  /// The shortlex-improved choice sequence.
  public let sequence: ChoiceSequence

  /// The fresh tree produced by materializing the improved sequence.
  public let tree: ChoiceTree

  /// The output value that witnesses the property failure.
  public let output: Output
}
