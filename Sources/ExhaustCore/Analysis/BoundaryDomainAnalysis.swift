//
//  BoundaryDomainAnalysis.swift
//  Exhaust
//

import Foundation

/// A parameter in the boundary model with synthetic values derived from boundary value analysis of the underlying generator operation.
public struct BoundaryParameter: @unchecked Sendable {
    public let index: Int
    public let values: [UInt64]
    public let domainSize: UInt64
    public let kind: BoundaryParameterKind
}

public enum BoundaryParameterKind: @unchecked Sendable {
    /// A chooseBits with a range too large for finite-domain analysis.
    /// Values are boundary representatives: {min, min+1, midpoint, max-1, max, 0 if in range}
    case chooseBits(range: ClosedRange<UInt64>, tag: TypeTag)

    /// A sequence length, capped at 2 for the boundary model.
    /// Values are: {0, 1, 2} (or subset if range is smaller)
    case sequenceLength(lengthRange: ClosedRange<UInt64>)

    /// An element within a boundary-modeled sequence.
    /// Same boundary values as chooseBits for the element generator.
    case sequenceElement(elementIndex: Int, range: ClosedRange<UInt64>, tag: TypeTag)

    /// A pick between branches (same as finite-domain pick).
    case pick(choices: ContiguousArray<ReflectiveOperation.PickTuple>)

    /// A chooseBits that was already small enough for finite-domain, kept as-is.
    case finiteChooseBits(range: ClosedRange<UInt64>, tag: TypeTag)
}

/// Result of boundary analysis — a synthetic finite domain suitable for IPOG.
public struct BoundaryDomainProfile: @unchecked Sendable {
    public let parameters: [BoundaryParameter]
    /// The original ChoiceTree from VACTI, used as a template for covering array replay.
    /// When present, `BoundaryCoveringArrayReplay.buildTree` walks this tree and substitutes
    /// parameter values at matching positions, preserving structural nodes like `.bind`.
    public let originalTree: ChoiceTree?

    public init(parameters: [BoundaryParameter], originalTree: ChoiceTree? = nil) {
        self.parameters = parameters
        self.originalTree = originalTree
    }

}

extension BoundaryDomainProfile: CoverageProfile {
    public var domainSizes: [UInt64] { parameters.map(\.domainSize) }
    public var parameterCount: Int { parameters.count }

    public var totalSpace: UInt64 {
        domainSizes.reduce(UInt64(1)) { result, domain in
            let (product, overflow) = result.multipliedReportingOverflow(by: domain)
            return overflow ? .max : product
        }
    }

    public func buildTree(from row: CoveringArrayRow) -> ChoiceTree? {
        BoundaryCoveringArrayReplay.buildTree(row: row, profile: self)
    }
}

// MARK: - Boundary Value Computation

/// Boundary value selection functions used by `ChoiceTreeAnalysis`.
public enum BoundaryDomainAnalysis {
    public static func computeBoundaryValues(min: UInt64, max: UInt64, tag: TypeTag) -> [UInt64] {
        switch tag {
        case .double, .float:
            computeFloatBoundaryValues(min: min, max: max, tag: tag)
        case let .date(lowerSeconds, intervalSeconds, timeZoneID):
            computeDateBoundaryValues(
                min: min,
                max: max,
                lowerSeconds: lowerSeconds,
                intervalSeconds: intervalSeconds,
                timeZoneID: timeZoneID
            )
        case .bits:
            [min, max]
        default:
            computeIntegerBoundaryValues(min: min, max: max, tag: tag)
        }
    }

    private static func computeIntegerBoundaryValues(
        min: UInt64,
        max: UInt64,
        tag: TypeTag
    ) -> [UInt64] {
        var values: Set<UInt64> = [min, max]
        if min < max { values.insert(min + 1) }
        if max > min { values.insert(max - 1) }
        values.insert(min + (max - min) / 2)

        if let zero = zeroBitPatternFor(tag: tag), zero >= min, zero <= max {
            values.insert(zero)
        }

        return values.sorted()
    }

    private static func computeFloatBoundaryValues(
        min: UInt64,
        max: UInt64,
        tag: TypeTag
    ) -> [UInt64] {
        // For float types, check if range is the full type range
        let isFullRange: Bool = switch tag {
        case .double:
            min == UInt64.min && max == UInt64.max
        case .float:
            min == UInt64(UInt32.min) && max == UInt64(UInt32.max)
        default:
            false
        }

        if isFullRange {
            return fullRangeFloatBoundaryValues(tag: tag)
        } else {
            return computeIntegerBoundaryValues(min: min, max: max, tag: tag)
        }
    }

    private static func fullRangeFloatBoundaryValues(tag: TypeTag) -> [UInt64] {
        var values = Set<UInt64>()
        switch tag {
        case .double:
            for c: Double in [
                -Double.greatestFiniteMagnitude, -1.0, -Double.leastNonzeroMagnitude,
                -0.0, 0.0, Double.leastNonzeroMagnitude,
                1.0, Double.greatestFiniteMagnitude,
                Double.nan, Double.infinity, -Double.infinity,
            ] {
                values.insert(c.bitPattern64)
            }
        case .float:
            for c: Float in [
                -Float.greatestFiniteMagnitude, -1.0, -Float.leastNonzeroMagnitude,
                -0.0, 0.0, Float.leastNonzeroMagnitude,
                1.0, Float.greatestFiniteMagnitude,
                Float.nan, Float.infinity, -Float.infinity,
            ] {
                values.insert(c.bitPattern64)
            }
        default:
            break
        }
        return values.sorted()
    }

    /// Returns the bit pattern for zero for the given type, if zero is a meaningful value.
    private static func zeroBitPatternFor(tag: TypeTag) -> UInt64? {
        switch tag {
        case .uint, .uint64, .uint32, .uint16, .uint8:
            0
        case .int:
            Int(0).bitPattern64
        case .int64:
            Int64(0).bitPattern64
        case .int32:
            Int32(0).bitPattern64
        case .int16:
            Int16(0).bitPattern64
        case .int8:
            Int8(0).bitPattern64
        case .double:
            Double(0.0).bitPattern64
        case .float:
            Float(0.0).bitPattern64
        case .date:
            0 // Step index 0 = lowerSeconds
        case .bits:
            0
        }
    }

    // MARK: - Date Boundary Values

    /// Seconds since reference date for well-known epoch points where date-handling bugs tend to cluster.
    private static let interestingDateEpochs: [Int64] = [
        0, // Reference date (2001-01-01 00:00:00 UTC)
        -978_307_200, // Unix epoch (1970-01-01 00:00:00 UTC)
        1_169_176_447, // Y2038 32-bit overflow (2038-01-19 03:14:07 UTC)
        -31_622_400, // Y2K (2000-01-01 00:00:00 UTC)
    ]

    /// Computes boundary values for date step indices.
    ///
    /// `min`/`max` are step indices in `[0, numSteps]`. Each step maps to real seconds as `lowerSeconds + step * intervalSeconds`. Boundary computation identifies interesting real-seconds values (epochs, calendar boundaries, DST transitions), then converts them to step indices. For each interesting point the ±1 step neighbors are also included.
    private static func computeDateBoundaryValues(
        min: UInt64,
        max: UInt64,
        lowerSeconds: Int64,
        intervalSeconds: Int64,
        timeZoneID: String
    ) -> [UInt64] {
        let minStep = Int64(bitPattern64: min)
        let maxStep = Int64(bitPattern64: max)
        guard maxStep > minStep, intervalSeconds > 0 else {
            return min == max ? [min] : [min, max].sorted()
        }

        let upperSeconds = lowerSeconds + maxStep * intervalSeconds
        let rangeSeconds = upperSeconds - lowerSeconds

        var values = Set<UInt64>()

        /// Convert a real-seconds value to a step index.
        /// Returns nil if the seconds value falls outside the range.
        func toStep(_ seconds: Int64) -> Int64? {
            let offset = seconds - lowerSeconds
            guard offset >= 0 else { return nil }
            let step = offset / intervalSeconds
            guard step <= maxStep else { return nil }
            return step
        }

        /// Insert a step index derived from a real-seconds value.
        func insert(_ seconds: Int64) {
            if let step = toStep(seconds) {
                values.insert(step.bitPattern64)
            }
        }

        /// Insert a step and its ±1 step neighbors.
        func insertWithNeighbors(_ seconds: Int64) {
            guard let step = toStep(seconds) else { return }
            values.insert(step.bitPattern64)
            if step + 1 <= maxStep { values.insert((step + 1).bitPattern64) }
            if step - 1 >= minStep { values.insert((step - 1).bitPattern64) }
        }

        // 1. Domain edges
        values.insert(minStep.bitPattern64)
        values.insert(maxStep.bitPattern64)

        // 2. BVA ±1 in the step domain
        if minStep + 1 <= maxStep { values.insert((minStep + 1).bitPattern64) }
        if maxStep - 1 >= minStep { values.insert((maxStep - 1).bitPattern64) }

        // 3. Midpoint step
        let midStep = minStep + (maxStep - minStep) / 2
        values.insert(midStep.bitPattern64)

        // 4. Key epoch points (converted to steps, with neighbors)
        for epoch in interestingDateEpochs where epoch >= lowerSeconds && epoch <= upperSeconds {
            insertWithNeighbors(epoch)
        }

        // 5. Calendar boundaries (first and last within range, with neighbors)
        let secondsPerDay: Int64 = 86400
        let secondsPerMonth: Int64 = 2_592_000 // 30 days
        let secondsPerYear: Int64 = 31_536_000 // 365 days

        for unitSeconds in [secondsPerDay, secondsPerMonth, secondsPerYear] {
            guard unitSeconds <= rangeSeconds else { continue }

            // First calendar boundary at or after lowerSeconds
            let firstBoundary: Int64
            if lowerSeconds >= 0 {
                firstBoundary = ((lowerSeconds + unitSeconds - 1) / unitSeconds) * unitSeconds
            } else {
                let divided = lowerSeconds / unitSeconds
                let remainder = lowerSeconds - divided * unitSeconds
                firstBoundary = remainder == 0 ? lowerSeconds : (divided + 1) * unitSeconds
            }

            if firstBoundary <= upperSeconds {
                insertWithNeighbors(firstBoundary)
            }

            // Last calendar boundary at or before upperSeconds
            let lastBoundary: Int64
            if upperSeconds >= 0 {
                lastBoundary = (upperSeconds / unitSeconds) * unitSeconds
            } else {
                let divided = upperSeconds / unitSeconds
                let remainder = upperSeconds - divided * unitSeconds
                lastBoundary = remainder == 0 ? upperSeconds : (divided - 1) * unitSeconds
            }

            if lastBoundary >= lowerSeconds, lastBoundary != firstBoundary {
                insertWithNeighbors(lastBoundary)
            }
        }

        // 6. DST transition times for the specified timezone (converted to steps, with neighbors)
        let transitions = DSTTransitions.inRange(
            lower: lowerSeconds,
            upper: upperSeconds,
            timeZoneID: timeZoneID
        )
        for transition in transitions {
            insertWithNeighbors(transition)
        }

        return values.sorted()
    }
}

// MARK: - DST Transition Computation

/// Computes DST transition times using Foundation's `TimeZone.nextDaylightSavingTimeTransition`.
public enum DSTTransitions {
    /// Returns DST transition times (seconds since reference date) that fall within [lower, upper] for the given timezone.
    ///
    /// Only the first and last transitions within [lower, upper] are included to keep boundary value counts small for large ranges. Each transition includes the transition moment itself plus the start and end of its calendar day.
    public static func inRange(lower: Int64, upper: Int64, timeZoneID: String) -> [Int64] {
        guard let zone = TimeZone(identifier: timeZoneID) else { return [] }

        let startDate = Date(timeIntervalSinceReferenceDate: TimeInterval(lower))
        let endDate = Date(timeIntervalSinceReferenceDate: TimeInterval(upper))

        var first: Date?
        var last: Date?
        var cursor = startDate
        while let next = zone.nextDaylightSavingTimeTransition(after: cursor),
              next <= endDate
        {
            if first == nil { first = next }
            last = next
            cursor = next
        }

        var picked = [Date]()
        if let first { picked.append(first) }
        if let last, last != first { picked.append(last) }

        var transitions = [Int64]()
        for transition in picked {
            transitions.append(Int64(transition.timeIntervalSinceReferenceDate))

            // Include the start and end of the transition day in this timezone.
            // DST bugs often manifest at the opposite edge of the transition day
            // (e.g., the 25th hour of a fall-back day, or midnight that doesn't
            // exist on a spring-forward-at-midnight day).
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let startOfDay = calendar.startOfDay(for: transition)
            transitions.append(Int64(startOfDay.timeIntervalSinceReferenceDate))
            if let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) {
                let endSeconds = Int64(endOfDay.timeIntervalSinceReferenceDate)
                transitions.append(endSeconds)
                transitions.append(endSeconds - 1)
            }
        }
        return transitions
    }
}
