import Foundation

enum DateTestRanges {
    static let year: ClosedRange<Date> = {
        let start = Date(timeIntervalSinceReferenceDate: 725_760_000)
        return start ... start.addingTimeInterval(86400 * 366)
    }()
}
