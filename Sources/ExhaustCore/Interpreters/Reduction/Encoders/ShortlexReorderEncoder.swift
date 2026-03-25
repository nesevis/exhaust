/// Sorts sibling elements within sequence containers by shortlex order.
///
/// Array elements produced by `Gen.array` appear as siblings in the choice sequence. When siblings are out of shortlex order — for example `[5, 0, 3]` in raw choice values — sorting them to `[0, 3, 5]` produces a shortlex-smaller overall sequence, which is a genuine shrink. This encoder finds such groups and proposes sorted candidates.
///
/// This is distinct from ``ReductionScheduler/humanOrderPostProcess(gen:sequence:tree:property:)`` which sorts by natural numeric order (Comparable: -1 < 0 < 1) as a cosmetic post-process. This encoder sorts by shortlex key (unsigned bit pattern: 0 < 1 < -1) and runs during fibre descent as a reduction step.
///
/// ## Strategy
///
/// For each eligible sibling group:
/// 1. **Full sort**: try sorting all siblings by shortlex key (one probe).
/// 2. **Pairwise swap**: if full sort is rejected, try swapping adjacent out-of-order pairs.
///
/// On acceptance, the encoder re-extracts eligible groups from the updated sequence and restarts — a reordering at one depth may enable further reordering at a shallower depth.
public struct ShortlexReorderEncoder: ComposableEncoder {
  public let name: EncoderName = .shortlexReorder
  public let phase: ReductionPhase = .valueMinimization

  // MARK: - State

  private var sequence = ChoiceSequence()
  private var eligibleGroups: [EligibleGroup] = []
  private var groupIndex = 0
  private var probePhase: ProbePhase = .fullSort
  private var needsReExtract = false

  private enum ProbePhase {
    case fullSort
    case pairwiseSwap(nextPairIndex: Int)
  }

  private struct EligibleGroup {
    let group: SiblingGroup
    var keys: [[ChoiceValue]]
  }

  // MARK: - ComposableEncoder

  public func estimatedCost(
    sequence: ChoiceSequence,
    tree: ChoiceTree,
    positionRange: ClosedRange<Int>,
    context: ReductionContext
  ) -> Int? {
    let groups = extractEligibleGroups(from: sequence)
    return groups.isEmpty ? nil : groups.count
  }

  public mutating func start(
    sequence: ChoiceSequence,
    tree: ChoiceTree,
    positionRange: ClosedRange<Int>,
    context: ReductionContext
  ) {
    self.sequence = sequence
    eligibleGroups = extractEligibleGroups(from: sequence)
    groupIndex = 0
    probePhase = .fullSort
    needsReExtract = false
  }

  public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
    // On acceptance, re-extract groups from the updated sequence.
    if lastAccepted {
      needsReExtract = true
    }

    while true {
      if needsReExtract {
        eligibleGroups = extractEligibleGroups(from: sequence)
        groupIndex = 0
        probePhase = .fullSort
        needsReExtract = false
      }

      guard groupIndex < eligibleGroups.count else { return nil }

      switch probePhase {
      case .fullSort:
        let candidate = buildFullSortCandidate()
        probePhase = .pairwiseSwap(nextPairIndex: 0)
        if let candidate {
          return candidate
        }
        // Full sort produced no improvement; fall through to pairwise.
        continue

      case let .pairwiseSwap(nextPairIndex):
        if lastAccepted {
          // Previous pairwise swap accepted — update sequence and restart.
          // needsReExtract is already set above.
          continue
        }
        if let (candidate, advancedIndex) = buildPairwiseSwapCandidate(
          startingAt: nextPairIndex
        ) {
          probePhase = .pairwiseSwap(nextPairIndex: advancedIndex)
          return candidate
        }
        // No more pairs in this group; advance to the next group.
        groupIndex += 1
        probePhase = .fullSort
        continue
      }
    }
  }

  // MARK: - Candidate Construction

  private mutating func buildFullSortCandidate() -> ChoiceSequence? {
    let eligible = eligibleGroups[groupIndex]
    let keys = eligible.keys

    let sortedIndices = keys.indices.sorted { lhs, rhs in
      shortlexKeyPrecedes(keys[lhs], keys[rhs])
    }
    guard sortedIndices != Array(keys.indices) else { return nil }

    let candidate = rebuildWithPermutation(
      group: eligible.group,
      sortedIndices: sortedIndices
    )
    guard candidate.shortLexPrecedes(sequence) else { return nil }
    return candidate
  }

  private mutating func buildPairwiseSwapCandidate(
    startingAt pairIndex: Int
  ) -> (candidate: ChoiceSequence, nextPairIndex: Int)? {
    let eligible = eligibleGroups[groupIndex]
    let keys = eligible.keys
    let siblingCount = keys.count

    var index = pairIndex
    while index + 1 < siblingCount {
      // Check if this adjacent pair is out of shortlex order.
      if shortlexKeyPrecedes(keys[index + 1], keys[index]) {
        var swappedIndices = Array(0 ..< siblingCount)
        swappedIndices.swapAt(index, index + 1)
        let candidate = rebuildWithPermutation(
          group: eligible.group,
          sortedIndices: swappedIndices
        )
        if candidate.shortLexPrecedes(sequence) {
          return (candidate, index + 1)
        }
      }
      index += 1
    }
    return nil
  }

  /// Reconstructs the sequence with siblings rearranged according to the given permutation.
  private func rebuildWithPermutation(
    group: SiblingGroup,
    sortedIndices: [Int]
  ) -> ChoiceSequence {
    let ranges = group.ranges
    let slices = ranges.map { Array(sequence[$0]) }
    let spanStart = ranges[0].lowerBound
    let spanEnd = ranges[ranges.count - 1].upperBound

    var rebuilt = ContiguousArray(sequence[..<spanStart])
    for position in 0 ..< ranges.count {
      if position > 0 {
        let gapStart = ranges[position - 1].upperBound + 1
        let gapEnd = ranges[position].lowerBound
        if gapStart < gapEnd {
          rebuilt.append(contentsOf: sequence[gapStart ..< gapEnd])
        }
      }
      rebuilt.append(contentsOf: slices[sortedIndices[position]])
    }
    if spanEnd + 1 < sequence.count {
      rebuilt.append(contentsOf: sequence[(spanEnd + 1)...])
    }

    return ChoiceSequence(rebuilt)
  }

  // MARK: - Group Extraction

  private func extractEligibleGroups(
    from sequence: ChoiceSequence
  ) -> [EligibleGroup] {
    let groups = ChoiceSequence.extractSiblingGroups(from: sequence)
    guard groups.isEmpty == false else { return [] }

    let bindIndex = BindSpanIndex(from: sequence)
    let bindInnerRanges = bindIndex.regions.map(\.innerRange)

    var eligible: [EligibleGroup] = []

    for group in groups {
      guard group.ranges.count >= 2 else { continue }

      // Exclude groups where any sibling overlaps a bind-inner range.
      var overlapsBindInner = false
      for siblingRange in group.ranges {
        for innerRange in bindInnerRanges {
          if siblingRange.overlaps(innerRange) {
            overlapsBindInner = true
            break
          }
        }
        if overlapsBindInner { break }
      }
      if overlapsBindInner { continue }

      // Extract comparison keys and require homogeneity.
      let keys = group.ranges.map {
        ChoiceSequence.siblingComparisonKey(from: sequence, range: $0)
      }
      let firstLength = keys[0].count
      guard firstLength > 0 else { continue }

      var homogeneous = true
      for key in keys {
        if key.count != firstLength {
          homogeneous = false
          break
        }
      }
      if homogeneous == false { continue }

      for position in 0 ..< firstLength {
        let firstTag = keys[0][position].tag
        for key in keys.dropFirst() {
          if key[position].tag != firstTag {
            homogeneous = false
            break
          }
        }
        if homogeneous == false { break }
      }
      if homogeneous == false { continue }

      // Only include groups that are out of shortlex order.
      let isSorted = (0 ..< keys.count - 1).allSatisfy { index in
        shortlexKeyPrecedes(keys[index], keys[index + 1])
          || keys[index] == keys[index + 1]
      }
      if isSorted { continue }

      eligible.append(EligibleGroup(group: group, keys: keys))
    }

    // Deepest-first so inner groups settle before outer groups.
    // Within same depth, rightmost-first to avoid index invalidation.
    eligible.sort { lhs, rhs in
      if lhs.group.depth != rhs.group.depth {
        return lhs.group.depth > rhs.group.depth
      }
      return lhs.group.ranges[0].lowerBound > rhs.group.ranges[0].lowerBound
    }

    return eligible
  }
}

// MARK: - Shortlex Key Comparison

/// Compares two arrays of ``ChoiceValue`` by shortlex order on raw choice values.
///
/// Uses ``ChoiceValue/shortlexKey`` (zigzag for signed, absolute magnitude for floats) with ``ChoiceValue/bitPattern64`` as tiebreaker. Shorter arrays precede longer ones. This is distinct from `ChoiceValue.Comparable` (natural numeric order) and from `naturalOrderPrecedes` (signed interpretation).
private func shortlexKeyPrecedes(
  _ lhs: [ChoiceValue],
  _ rhs: [ChoiceValue]
) -> Bool {
  if lhs.count != rhs.count {
    return lhs.count < rhs.count
  }
  for (left, right) in zip(lhs, rhs) {
    let leftKey = left.shortlexKey
    let rightKey = right.shortlexKey
    if leftKey < rightKey { return true }
    if leftKey > rightKey { return false }
    let leftBits = left.bitPattern64
    let rightBits = right.bitPattern64
    if leftBits < rightBits { return true }
    if leftBits > rightBits { return false }
  }
  return false
}
