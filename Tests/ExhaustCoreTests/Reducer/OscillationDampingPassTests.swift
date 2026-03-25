//
//  OscillationDampingPassTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

import Testing
@testable import ExhaustCore

@Suite("OscillationDampingPass")
struct OscillationDampingPassTests {
  @Test("Detects oscillation and produces shortlex-smaller candidate")
  func detectsOscillation() throws {
    // Two coordinates at 500 and 499, both oscillating toward 0.
    let seq = makePairSequence(500, 499)
    let gen = pairGen

    var encoder = OscillationDampingPass()

    // First call: no previous origins, should return nil.
    var budget = 100
    let firstResult = try encoder.encode(
      gen: gen,
      sequence: seq,
      tree: ChoiceTree.just(""),
      currentOrigins: makeOrigins([(1, 500), (2, 499)]),
      fallbackTree: nil,
      property: { _ in true },
      budget: &budget
    )
    #expect(firstResult == nil)

    // Second call: previous origins exist, current moved by 1 each.
    budget = 100
    let secondResult = try encoder.encode(
      gen: gen,
      sequence: seq,
      tree: ChoiceTree.just(""),
      currentOrigins: makeOrigins([(1, 499), (2, 498)]),
      fallbackTree: nil,
      property: pairAlwaysFails,
      budget: &budget
    )
    #expect(secondResult != nil)
    if let result = secondResult {
      #expect(result.sequence.shortLexPrecedes(seq))
    }
  }

  @Test("No detection when delta is large (normal convergence)")
  func largeDeltaNoDetection() throws {
    let seq = makePairSequence(500, 499)

    var encoder = OscillationDampingPass()

    // Cycle 1: bounds at 500, 499.
    var budget = 100
    _ = try encoder.encode(
      gen: pairGen,
      sequence: seq,
      tree: ChoiceTree.just(""),
      currentOrigins: makeOrigins([(1, 500), (2, 499)]),
      fallbackTree: nil,
      property: pairAlwaysFails,
      budget: &budget
    )

    // Cycle 2: bounds moved by 200 each — normal convergence.
    budget = 100
    let result = try encoder.encode(
      gen: pairGen,
      sequence: seq,
      tree: ChoiceTree.just(""),
      currentOrigins: makeOrigins([(1, 300), (2, 299)]),
      fallbackTree: nil,
      property: pairAlwaysFails,
      budget: &budget
    )
    #expect(result == nil)
  }

  @Test("No detection when only one coordinate oscillates")
  func singleCoordinateNoGroup() throws {
    let seq = makePairSequence(500, 10)

    var encoder = OscillationDampingPass()

    // Cycle 1.
    var budget = 100
    _ = try encoder.encode(
      gen: pairGen,
      sequence: seq,
      tree: ChoiceTree.just(""),
      currentOrigins: makeOrigins([(1, 500), (2, 10)]),
      fallbackTree: nil,
      property: pairAlwaysFails,
      budget: &budget
    )

    // Cycle 2: coordinate 1 moved by 1, coordinate 2 moved by 5.
    budget = 100
    let result = try encoder.encode(
      gen: pairGen,
      sequence: seq,
      tree: ChoiceTree.just(""),
      currentOrigins: makeOrigins([(1, 499), (2, 5)]),
      fallbackTree: nil,
      property: pairAlwaysFails,
      budget: &budget
    )
    #expect(result == nil)
  }

  @Test("No detection on first cycle (no previous origins)")
  func firstCycleNoDetection() throws {
    let seq = makePairSequence(500, 499)

    var encoder = OscillationDampingPass()
    var budget = 100
    let result = try encoder.encode(
      gen: pairGen,
      sequence: seq,
      tree: ChoiceTree.just(""),
      currentOrigins: makeOrigins([(1, 500), (2, 499)]),
      fallbackTree: nil,
      property: pairAlwaysFails,
      budget: &budget
    )
    #expect(result == nil)
  }

  @Test("Coordinates in opposite directions are not grouped")
  func oppositeDirectionsNotGrouped() throws {
    let seq = makePairSequence(499, 101)

    var encoder = OscillationDampingPass()

    // Cycle 1: coordinate 1 at 500, coordinate 2 at 100.
    var budget = 100
    _ = try encoder.encode(
      gen: pairGen,
      sequence: seq,
      tree: ChoiceTree.just(""),
      currentOrigins: makeOrigins([(1, 500), (2, 100)]),
      fallbackTree: nil,
      property: pairAlwaysFails,
      budget: &budget
    )

    // Cycle 2: coordinate 1 moved down by 1, coordinate 2 moved up by 1.
    // Target for both is 0 (unsigned, no range constraint), so both move
    // downward in the detection logic. But coordinate 2 moved UP (100 → 101),
    // away from target 0. It won't pass the "same direction" check since
    // its delta makes remaining LARGER, not smaller.
    budget = 100
    let result = try encoder.encode(
      gen: pairGen,
      sequence: seq,
      tree: ChoiceTree.just(""),
      currentOrigins: makeOrigins([(1, 499), (2, 101)]),
      fallbackTree: nil,
      property: pairAlwaysFails,
      budget: &budget
    )
    // Coordinate 2 moved away from target → not an oscillation suspect.
    // Only coordinate 1 qualifies → group of 1 → no joint search.
    #expect(result == nil)
  }
}

// MARK: - Helpers

/// Builds a sequence matching `pairGen`: [grpOpen, val(a), val(b), grpClose].
private func makePairSequence(_ first: UInt64, _ second: UInt64) -> ChoiceSequence {
  ChoiceSequence([
    .group(true),
    .value(.init(
      choice: .unsigned(first, .uint64),
      validRange: 0 ... UInt64.max,
      isRangeExplicit: false
    )),
    .value(.init(
      choice: .unsigned(second, .uint64),
      validRange: 0 ... UInt64.max,
      isRangeExplicit: false
    )),
    .group(false),
  ])
}

private func makeOrigins(
  _ entries: [(index: Int, bound: UInt64)]
) -> [Int: ConvergedOrigin] {
  var origins = [Int: ConvergedOrigin]()
  for entry in entries {
    origins[entry.index] = ConvergedOrigin(
      bound: entry.bound,
      signal: .monotoneConvergence,
      configuration: .binarySearchSemanticSimplest,
      cycle: 0
    )
  }
  return origins
}

private nonisolated(unsafe) let pairAlwaysFails: ((UInt64, UInt64)) -> Bool = {
  _ in false
}

/// Generator producing `(UInt64, UInt64)` from two `chooseBits`.
/// Sequence structure: [grpOpen, val, val, grpClose].
private let pairGen: ReflectiveGenerator<(UInt64, UInt64)> = Gen.zip(
  Gen.choose(in: UInt64.min ... UInt64.max),
  Gen.choose(in: UInt64.min ... UInt64.max)
)
