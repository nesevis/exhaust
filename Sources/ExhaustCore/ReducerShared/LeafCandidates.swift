//
//  LeafCandidates.swift
//  Exhaust
//

// MARK: - Leaf Proposal Candidates

/// Selects values on both sides of an integer controller so nested compositions can compensate between bind controllers.
///
/// Small domains are exhaustive, ordered by increasing distance from the current value. Large domains cover the reduction target, the current value's neighbours, and alternating range ends, bounded by ``candidateBudget``. Unlike a rejected binary-search ladder, domain enumeration can increase a controller while a later nested controller decreases enough to make the complete candidate shortlex-smaller.
enum LeafCandidates {
    static let exhaustiveThreshold: UInt64 = 32
    static let candidateBudget = 64

    /// Materializes the fixed midpoint order obtained when every binary-search probe is rejected. Reuses the adaptive stepper's directional and endpoint rules rather than approximating them.
    static func rejectedBinarySearch(current: UInt64, target: UInt64) -> [UInt64] {
        guard current != target else {
            return []
        }
        var stepper = switch current > target {
            case true:
                BinarySearchStepper(lo: target, hi: current, direction: .findSmallest)
            case false:
                BinarySearchStepper(lo: current, hi: target, direction: .findLargest)
        }
        var values: [UInt64] = []
        var next = stepper.start()
        while let value = next {
            values.append(value)
            next = stepper.advance(lastAccepted: false)
        }
        return values
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
