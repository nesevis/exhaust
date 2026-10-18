/// Shares exact unsigned factor reduction between relation discovery, rational redistribution, and coordinated common-divisor proposals.
enum ReductionIntegerMath {
    /// Reduces denominator factors with remainders so intermediate products cannot overflow.
    static func greatestCommonDivisor(_ first: UInt64, _ second: UInt64) -> UInt64 {
        var dividend = first
        var divisor = second
        while divisor != 0 {
            let remainder = dividend % divisor
            dividend = divisor
            divisor = remainder
        }
        return dividend
    }
}
