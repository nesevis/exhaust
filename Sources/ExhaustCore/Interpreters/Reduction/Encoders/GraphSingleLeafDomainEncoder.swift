//
//  GraphSingleLeafDomainEncoder.swift
//  Exhaust
//

// MARK: - Graph Single-Leaf Domain Encoder

/// Enumerates values on both sides of one integer leaf so a nested composition can compensate between bind controllers.
///
/// Small domains are exhaustive, ordered by increasing distance from the current value. Large domains cover the reduction target, the current value's neighbours, and alternating range ends, bounded by ``candidateBudget``. Unlike ``GraphBinarySearchEncoder``, this encoder can increase a controller while a later nested controller decreases enough to make the complete candidate shortlex-smaller.
struct GraphSingleLeafDomainEncoder: GraphEncoder {
    let name: EncoderName = .valueSearch

    static let exhaustiveThreshold: UInt64 = 32
    static let candidateBudget = 64

    private var leafNodeID = -1
    private var sequenceIndex = -1
    private var typeTag: TypeTag = .uint
    private var validRange: ClosedRange<UInt64>?
    private var isRangeExplicit = false
    private var baseSequence: ChoiceSequence = []
    private var candidateBitPatterns: [UInt64] = []
    private var candidateIndex = 0
    private let includesCurrent: Bool

    init(includesCurrent: Bool = false) {
        self.includesCurrent = includesCurrent
    }

    mutating func start(scope: EncoderInput) {
        leafNodeID = -1
        sequenceIndex = -1
        candidateBitPatterns = []
        candidateIndex = 0
        baseSequence = scope.baseSequence

        guard case let .minimize(.valueLeaves(integerScope)) = scope.transformation.operation,
              let entry = integerScope.leaves.first,
              entry.nodeID < scope.graph.nodes.count,
              case let .chooseBits(metadata) = scope.graph.nodes[entry.nodeID].kind,
              metadata.typeTag.isFloatingPoint == false,
              let range = scope.graph.nodes[entry.nodeID].positionRange,
              range.lowerBound < scope.baseSequence.count
        else {
            return
        }

        leafNodeID = entry.nodeID
        sequenceIndex = range.lowerBound
        typeTag = metadata.typeTag
        validRange = metadata.validRange
        isRangeExplicit = metadata.isRangeExplicit
        let domain = metadata.validRange ?? metadata.typeTag.bitPatternRange
        let current = metadata.value.bitPattern64
        let target = metadata.value.reductionTarget(in: metadata.validRange)
        candidateBitPatterns = Self.candidates(
            in: domain,
            current: current,
            target: target,
            includesCurrent: includesCurrent
        )
    }

    mutating func nextProbe(
        into candidate: inout ChoiceSequence,
        lastAccepted _: Bool
    ) -> EncoderProbe? {
        guard leafNodeID >= 0, candidateIndex < candidateBitPatterns.count else {
            return nil
        }

        let bitPattern = candidateBitPatterns[candidateIndex]
        candidateIndex += 1
        let newChoice = ChoiceValue(
            typeTag.makeConvertible(bitPattern64: bitPattern),
            tag: typeTag
        )
        candidate = baseSequence
        candidate[sequenceIndex] = .value(.init(
            choice: newChoice,
            validRange: validRange,
            isRangeExplicit: isRangeExplicit
        ))
        return .leafValues([LeafChange(
            leafNodeID: leafNodeID,
            newValue: newChoice,
            mayReshape: false
        )])
    }

    /// Candidate bit patterns for one controller, in probe order.
    ///
    /// A small domain whose current value lies outside it yields no candidates: enumerating outward from a value the domain does not contain would propose values the domain does not admit.
    static func candidates(
        in domain: ClosedRange<UInt64>,
        current: UInt64,
        target: UInt64,
        includesCurrent: Bool
    ) -> [UInt64] {
        if domain.saturatingCount <= exhaustiveThreshold {
            guard domain.contains(current) else {
                return []
            }
            var values: [UInt64] = includesCurrent ? [current] : []
            let targetCount = Int(domain.saturatingCount) - (includesCurrent ? 0 : 1)
            var offset: UInt64 = 1
            while values.count < targetCount {
                let (higher, higherOverflowed) = current.addingReportingOverflow(offset)
                if higherOverflowed == false, domain.contains(higher) {
                    values.append(higher)
                }
                if offset <= current - domain.lowerBound {
                    values.append(current - offset)
                }
                offset += 1
            }
            return values
        }

        var values: [UInt64] = includesCurrent ? [current] : []
        var seen: Set<UInt64> = includesCurrent ? [current] : []
        func append(_ value: UInt64) {
            guard domain.contains(value), value != current, seen.insert(value).inserted else {
                return
            }
            values.append(value)
        }

        append(target)
        if current > domain.lowerBound {
            append(current - 1)
        }
        if current < domain.upperBound {
            append(current + 1)
        }

        let span = domain.upperBound - domain.lowerBound
        var offset: UInt64 = 0
        while values.count < candidateBudget {
            append(domain.lowerBound + offset)
            guard values.count < candidateBudget else {
                break
            }
            append(domain.upperBound - offset)
            guard offset < span else {
                break
            }
            offset += 1
        }
        return values
    }
}
