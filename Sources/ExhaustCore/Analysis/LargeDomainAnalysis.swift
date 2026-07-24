//
//  LargeDomainAnalysis.swift
//  Exhaust
//

import Foundation

/// A parameter in the screening model with synthetic values derived from problematic-value analysis of the underlying generator operation.
package struct ScreeningParameter: @unchecked Sendable {
    // @unchecked Sendable: stores `ScreeningParameterKind`, which in its `.pick` case holds generator closures the compiler cannot verify as Sendable. All closures are framework-controlled and do not capture shared mutable state.

    /// Zero-based parameter index in the covering array model.
    package let index: Int
    /// Synthetic problematic values as raw bit patterns.
    package let values: [UInt64]
    /// Number of distinct values in this parameter's synthetic domain.
    package let domainSize: UInt64
    /// The generator operation this parameter was derived from.
    package let kind: ScreeningParameterKind

    /// Returns a copy with a replacement problematic value set.
    package func withValues(_ newValues: [UInt64]) -> ScreeningParameter {
        ScreeningParameter(index: index, values: newValues, domainSize: UInt64(newValues.count), kind: kind)
    }
}

/// Classifies the generator operation that produced a screening parameter, determining which problematic-value strategy (range endpoints, sequence lengths, pick branches, or composite encoding) applies.
package enum ScreeningParameterKind: @unchecked Sendable {
    // @unchecked Sendable: the `.pick` case stores `ContiguousArray<ReflectiveOperation.PickTuple>`, which contains generator closures the compiler cannot verify as Sendable. All closures are framework-controlled and do not capture shared mutable state.

    /// A chooseBits with a range too large to enumerate. Values are problematic representatives: {min, min+1, midpoint, max-1, max, 0 if in range}
    case chooseBits(range: ClosedRange<UInt64>, tag: TypeTag)

    /// A sequence length (legacy). Used by the ``SequenceCoveringArray`` pipeline. Modern sequences use `.compositeSequence`. Values are {0, 1, 2, lowerBound} filtered to the declared length range.
    case sequenceLength(lengthRange: ClosedRange<UInt64>)

    /// An element within a problematic-modeled sequence (legacy). Used by the ``SequenceCoveringArray`` pipeline and internally within `.compositeSequence` element slot parameters. Same problematic values as chooseBits for the element generator.
    case sequenceElement(elementIndex: Int, range: ClosedRange<UInt64>, tag: TypeTag)

    /// A pick between branches (same as enumerable pick).
    case pick(choices: ContiguousArray<ReflectiveOperation.PickTuple>)

    /// A chooseBits that was already small enough for enumerable, kept as-is.
    case enumerableChooseBits(range: ClosedRange<UInt64>, tag: TypeTag)

    /// A composite sequence parameter encoding `(length, [element values])` tuples into a single flat domain.
    ///
    /// The domain enumerates all valid configurations: empty (if allowed), single-element, and optionally two-element problematic combinations. During replay, the composite index is decomposed via ``SequenceLengthSlot`` lookup and mixed-radix arithmetic back into a length and per-element problematic value indices. When `halvedPairs` is true, length-2 slots split each element's problematic values between positions so that position 0 uses the first half and position 1 uses the second half. Length ≤1 slots always use the full problematic set.
    case compositeSequence(
        lengthRange: ClosedRange<UInt64>,
        elementSlotParams: [[ScreeningParameter]],
        halvedPairs: Bool,
        lengthSlots: [SequenceLengthSlot]
    )
}

/// Maps a range of flat composite indices to a specific sequence length and its element parameters.
package struct SequenceLengthSlot: Sendable {
    /// The sequence length this slot represents.
    package let length: UInt64
    /// Starting offset of this slot in the composite domain.
    package let flatOffset: UInt64
    /// Number of composite indices this slot covers. Equals the product of element domain sizes for this length, or one for length zero.
    package let contribution: UInt64
    /// Number of analyzed element slots active at this length.
    package let activeElementCount: Int
}

/// Result of problematic-value analysis — a small synthetic domain suitable for covering array generation.
package struct LargeDomainProfile: @unchecked Sendable {
    // @unchecked Sendable: stores `[ScreeningParameter]` and `ChoiceTree?`. `ChoiceTree` nodes contain generator closures the compiler cannot verify as Sendable. All closures are framework-controlled and do not capture shared mutable state.

    /// The screening parameters extracted from the generator's choice tree.
    package let parameters: [ScreeningParameter]
    /// The original ChoiceTree from VACTI, used as a template for covering array replay. When present, ``LargeDomainCoveringArrayReplay`` walks this tree and substitutes parameter values at matching positions, preserving structural nodes like `.bind`.
    package let originalTree: ChoiceTree?

    /// Creates a profile with the given parameters and optional original tree template.
    package init(parameters: [ScreeningParameter], originalTree: ChoiceTree? = nil) {
        self.parameters = parameters
        self.originalTree = originalTree
    }
}

extension LargeDomainProfile: ScreeningProfile {
    package var domainSizes: [UInt64] {
        parameters.map(\.domainSize)
    }

    package var parameterCount: Int {
        parameters.count
    }

    package var totalSpace: UInt64 {
        domainSizes.reduce(UInt64(1)) { result, domain in
            let (product, overflow) = result.multipliedReportingOverflow(by: domain)
            return overflow ? .max : product
        }
    }

    package func buildTree(from row: CoveringArrayRow) -> ChoiceTree? {
        LargeDomainCoveringArrayReplay.buildTree(row: row, profile: self)
    }
}

// MARK: - Problematic Value Computation

/// Problematic value selection functions used by ``ChoiceTreeAnalysis``.
package enum ProblematicValues {
    /// Unicode scalar values that are prone to causing problems in string-processing code.
    ///
    /// ``ScalarRangeSet`` converts these to flat indices during construction so that ``computeProblematicValues(min:max:tag:)`` receives pre-computed, index-space problematic values via the ``TypeTag/character(problematicIndices:)`` tag.
    package static let interestingCharacterScalars: [UInt32] = [
        0, // Null: truncates C-interop strings, invisible in output
        34, // Double quote: delimiter in JSON, SQL, HTML attributes, CSV, and shell commands
        92, // Backslash: escape character in JSON, regex, file paths, shell commands, and string literals
        768, // Combining grave accent: merges with preceding character into a single grapheme cluster
        6158, // Mongolian vowel separator: reclassified from space (Zs) to format (Cf) in Unicode 6.3
        8205, // Zero-width joiner: glues adjacent emoji into a single grapheme cluster
        8232, // Line separator: acts as a newline but is not matched by \n
        8238, // Right-to-left override: reverses display order of subsequent characters
        8239, // Narrow no-break space: visually identical to a space but fails equality and trim checks
        65279, // BOM: invisible at file start, zero-width no-break space elsewhere
        65533, // Replacement character: injected on invalid decode, corrupts serialization round-trips
        127_995, // Emoji skin tone modifier: combines with preceding emoji to form a single grapheme cluster
        128_078, // Thumbs down: supplementary plane emoji, requires UTF-16 surrogate pair
    ]

    /// Computes problematic bit-patterns for a `[min, max]` domain using type-specific problematic-value analysis rules.
    package static func computeProblematicValues(min: UInt64, max: UInt64, tag: TypeTag, payload: TypeTagPayload? = nil) -> [UInt64] {
        switch tag {
            case _ where tag.isFloatingPoint:
                computeFloatProblematicValues(min: min, max: max, tag: tag)
            case .date:
                if case let .date(grid) = payload {
                    computeDateProblematicValues(min: min, max: max, grid: grid)
                } else {
                    computeIntegerProblematicValues(min: min, max: max, tag: tag)
                }
            case .bits:
                [min, max]
            case .character:
                if case let .character(problematicIndices) = payload {
                    problematicIndices
                } else {
                    [min, max]
                }
            default:
                computeIntegerProblematicValues(min: min, max: max, tag: tag)
        }
    }

    private static func computeIntegerProblematicValues(
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

    private static func computeFloatProblematicValues(
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
            case .float16:
                min == UInt64(UInt16.min) && max == UInt64(UInt16.max)
            default:
                false
        }

        if isFullRange {
            return fullRangeFloatProblematicValues(tag: tag)
        } else {
            return computeIntegerProblematicValues(min: min, max: max, tag: tag)
        }
    }

    private static func fullRangeFloatProblematicValues(tag: TypeTag) -> [UInt64] {
        var values = Set<UInt64>()
        switch tag {
            case .double:
                let doubles = [
                    -Double.greatestFiniteMagnitude,
                    -1.0,
                    -Double.leastNormalMagnitude,
                    -Double.leastNonzeroMagnitude,
                    -0.0,
                    0.0,
                    Double.leastNonzeroMagnitude,
                    Double.leastNormalMagnitude,
                    Double.ulpOfOne,
                    1.0,
                    1.0.nextUp,
                    Double.greatestFiniteMagnitude,
                    Double.nan,
                    Double.infinity,
                    -Double.infinity,
                ]
                values.formUnion(doubles.map(\.bitPattern64))
            case .float:
                let floats = [
                    -Float.greatestFiniteMagnitude,
                    -1.0,
                    -Float.leastNormalMagnitude,
                    -Float.leastNonzeroMagnitude,
                    -0.0,
                    0.0,
                    Float.leastNonzeroMagnitude,
                    Float.leastNormalMagnitude,
                    Float.ulpOfOne,
                    1.0,
                    Float(1.0).nextUp,
                    Float.greatestFiniteMagnitude,
                    Float.nan,
                    Float.infinity,
                    -Float.infinity,
                ]
                values.formUnion(floats.map(\.bitPattern64))
            case .float16:
                #if arch(arm64) || arch(arm64_32)
                    if #available(macOS 11, iOS 14, tvOS 14, watchOS 7, *) {
                        let floats = [
                            -Float16.greatestFiniteMagnitude,
                            -Float16(1.0),
                            -Float16.leastNormalMagnitude,
                            -Float16.leastNonzeroMagnitude,
                            -Float16(0.0),
                            Float16(0.0),
                            Float16.leastNonzeroMagnitude,
                            Float16.leastNormalMagnitude,
                            Float16.ulpOfOne,
                            Float16(1.0),
                            Float16(1.0).nextUp,
                            Float16.greatestFiniteMagnitude,
                            Float16.nan,
                            Float16.infinity,
                            -Float16.infinity,
                        ]
                        values.formUnion(floats.map(\.bitPattern64))
                    }
                #endif
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
            case .float16:
                Float16Emulation.encodedBitPattern(from: 0.0)
            case .date:
                0 // Step index 0 = lowerSeconds
            case .bits:
                0
            case .character:
                0 // Index 0 = first scalar in the ScalarRangeSet
            case .depthControl:
                0 // Depth 0 = shallowest (base case)
            case .laneControl:
                0 // Marker 0 = prefix (sequential)
        }
    }

    // MARK: - Date Problematic Values

    /// Seconds since reference date for well-known epoch points where date-handling bugs tend to cluster.
    private static let interestingDateEpochs: [Int64] = [
        0, // Reference date (2001-01-01 00:00:00 UTC)
        -978_307_200, // Unix epoch (1970-01-01 00:00:00 UTC)
        1_169_176_447, // Y2038 32-bit overflow (2038-01-19 03:14:07 UTC)
        -31_622_400, // Y2K (2000-01-01 00:00:00 UTC)
    ]

    /// Computes problematic values for date step indices.
    ///
    /// `min`/`max` are step indices in `[0, numSteps]`. The grid maps each step to real seconds — affinely for fixed grids, via calendar arithmetic for calendar grids. Problematic-value computation identifies interesting real-seconds values (epochs, calendar boundaries, DST transitions), then converts them to step indices with the same backward map reflection uses, so boundary instants that lie on the grid land exactly on their grid points. For each interesting point the ±1 step neighbors are also included.
    private static func computeDateProblematicValues(
        min: UInt64,
        max: UInt64,
        grid: DateGrid
    ) -> [UInt64] {
        let minStep = Int64(bitPattern64: min)
        let maxStep = Int64(bitPattern64: max)
        guard maxStep > minStep else {
            return min == max ? [min] : [min, max].sorted()
        }

        let lowerSeconds = grid.lowerSeconds
        let timeZoneID = grid.timeZoneID
        let upperSeconds = grid.secondsAtStep(maxStep)

        var values = Set<UInt64>()

        /// Convert a real-seconds value to a step index.
        /// Returns nil if the seconds value falls outside the range.
        func toStep(_ seconds: Int64) -> Int64? {
            guard seconds >= lowerSeconds, seconds <= upperSeconds else { return nil }
            let step = grid.stepIndex(flooring: seconds)
            guard step >= minStep, step <= maxStep else { return nil }
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

        // 5. Gregorian calendar adoption gap (1582-10-15)
        // Foundation collapses Oct 5–14: Oct 4 and Oct 15 are 86400s apart. Include both sides when steps are too fine to bridge the gap.
        // See: casualprogrammer.com/blog/2026/03-27-old-dates-in-apple-sdks.html
        let gregorianAdoption: Int64 = -13_197_600_000
        if gregorianAdoption >= lowerSeconds, gregorianAdoption <= upperSeconds {
            insertWithNeighbors(gregorianAdoption)
            if grid.form.approximateSecondsPerStep < 86400 {
                let lastJulianDay: Int64 = -13_197_686_400
                if lastJulianDay >= lowerSeconds {
                    insertWithNeighbors(lastJulianDay)
                }
            }
        }

        // 6. Calendar boundaries (first and last month/year start within range, plus leap days)
        let calendarBoundaries = CalendarBoundaries.inRange(
            lower: lowerSeconds,
            upper: upperSeconds,
            timeZoneID: timeZoneID
        )
        for boundary in calendarBoundaries {
            insertWithNeighbors(boundary)
        }

        // 7. DST transition times for the specified timezone (converted to steps, with neighbors)
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
package enum DSTTransitions {
    /// Returns DST transition times (seconds since reference date) that fall within [lower, upper] for the given timezone.
    ///
    /// Only the first and last transitions within [lower, upper] are included to keep problematic value counts small for large ranges. Each transition includes the transition moment itself, the start and end of its calendar day, and the day's true midpoint (which differs from hour 12 on non-24-hour days).
    package static func inRange(lower: Int64, upper: Int64, timeZoneID: String) -> [Int64] {
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
            // DST bugs often manifest at the opposite edge of the transition day (for example, the 25th hour of a fall-back day, or midnight that doesn't exist on a spring-forward-at-midnight day).
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let startOfDay = calendar.startOfDay(for: transition)
            transitions.append(Int64(startOfDay.timeIntervalSinceReferenceDate))
            if let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) {
                let endSeconds = Int64(endOfDay.timeIntervalSinceReferenceDate)
                transitions.append(endSeconds)
                transitions.append(endSeconds - 1)

                // Midpoint of the transition day: 11:30 local on a 23-hour spring-forward day, 12:30 on a 25-hour fall-back day. Catches nearest-day rounding bugs that assume the midpoint of any day is hour 12.
                let startSeconds = Int64(startOfDay.timeIntervalSinceReferenceDate)
                transitions.append(startSeconds + (endSeconds - startSeconds) / 2)
            }
        }
        return transitions
    }
}

// MARK: - Calendar Boundary Computation

/// Computes real month starts, year starts, leap day, and month-end last-day boundaries within a date range.
package enum CalendarBoundaries {
    /// Returns seconds-since-reference-date for the first and last month start, year start, Feb 29, and the start of the last day for each distinct month length (28, 29, 30, 31 days) within [lower, upper].
    package static func inRange(lower: Int64, upper: Int64, timeZoneID: String) -> [Int64] {
        let zone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let startDate = Date(timeIntervalSinceReferenceDate: TimeInterval(lower))
        let endDate = Date(timeIntervalSinceReferenceDate: TimeInterval(upper))

        var results = [Int64]()

        // Month starts: first and last within range
        if let firstMonth = calendar.nextDate(after: startDate, matching: DateComponents(day: 1), matchingPolicy: .nextTime),
           firstMonth <= endDate
        {
            results.append(Int64(firstMonth.timeIntervalSinceReferenceDate))

            var cursor = firstMonth
            var lastMonth = firstMonth
            while let next = calendar.date(byAdding: .month, value: 1, to: cursor),
                  next <= endDate
            {
                lastMonth = next
                cursor = next
            }
            if lastMonth != firstMonth {
                results.append(Int64(lastMonth.timeIntervalSinceReferenceDate))
            }
        }

        // Year starts: first and last within range
        if let firstYear = calendar.nextDate(after: startDate, matching: DateComponents(month: 1, day: 1), matchingPolicy: .nextTime),
           firstYear <= endDate
        {
            results.append(Int64(firstYear.timeIntervalSinceReferenceDate))

            var cursor = firstYear
            var lastYear = firstYear
            while let next = calendar.date(byAdding: .year, value: 1, to: cursor),
                  next <= endDate
            {
                lastYear = next
                cursor = next
            }
            if lastYear != firstYear {
                results.append(Int64(lastYear.timeIntervalSinceReferenceDate))
            }
        }

        // End-of-month rollover: last second of the month before the last month start (where day 31 → day 1 happens)
        if let lastMonth = results.last(where: { $0 > lower }),
           let lastMonthDate = Optional(Date(timeIntervalSinceReferenceDate: TimeInterval(lastMonth))),
           let endOfPreviousMonth = calendar.date(byAdding: .second, value: -1, to: lastMonthDate)
        {
            let seconds = Int64(endOfPreviousMonth.timeIntervalSinceReferenceDate)
            if seconds >= lower {
                results.append(seconds)
            }
        }

        // Local midnight: start of the day nearest the range midpoint in the configured timezone
        let midSeconds = lower + (upper - lower) / 2
        let midDate = Date(timeIntervalSinceReferenceDate: TimeInterval(midSeconds))
        let midnight = calendar.startOfDay(for: midDate)
        let midnightSeconds = Int64(midnight.timeIntervalSinceReferenceDate)
        if midnightSeconds >= lower, midnightSeconds <= upper {
            results.append(midnightSeconds)
        }

        // Leap day (Feb 29): last occurrence within range
        let endYear = calendar.component(.year, from: endDate)
        var leapYear = endYear
        while leapYear % 4 != 0 || (leapYear % 100 == 0 && leapYear % 400 != 0) {
            leapYear -= 1
        }
        if leapYear >= calendar.component(.year, from: startDate) {
            let components = DateComponents(year: leapYear, month: 2, day: 29)
            if let leapDay = calendar.date(from: components) {
                let seconds = Int64(leapDay.timeIntervalSinceReferenceDate)
                if seconds >= lower, seconds <= upper {
                    results.append(seconds)
                }
            }
        }

        // Month-end last-day variants: start of the last day for each distinct month length (28, 29, 30, 31 days). Month-addition clamping behaves differently for each — Jan 31 + 1 month clamps to Feb 28, but Jan 30 + 1 month clamps to Feb 29 in a leap year.
        var seenMonthLengths = Set<Int>()
        var monthCursor = endDate
        for _ in 0 ..< 12 {
            guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: monthCursor)
            else { break }
            let daysInMonth = calendar.range(of: .day, in: .month, for: previousMonth)!.count
            if seenMonthLengths.insert(daysInMonth).inserted {
                let year = calendar.component(.year, from: previousMonth)
                let month = calendar.component(.month, from: previousMonth)
                if let lastDay = calendar.date(from: DateComponents(year: year, month: month, day: daysInMonth)) {
                    let seconds = Int64(lastDay.timeIntervalSinceReferenceDate)
                    if seconds >= lower, seconds <= upper {
                        results.append(seconds)
                    }
                }
            }
            monthCursor = previousMonth
            if seenMonthLengths.count >= 4 { break }
        }

        return results
    }
}
