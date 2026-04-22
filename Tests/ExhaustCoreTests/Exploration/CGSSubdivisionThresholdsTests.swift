import ExhaustCore
import Testing

@Suite("CGSSubdivisionThresholds")
struct CGSSubdivisionThresholdsTests {
    @Test("Default thresholds match historical hardcoded values")
    func defaultThresholds() {
        let thresholds = CGSSubdivisionThresholds.default
        #expect(thresholds.minimumRangeSize == 1000)
        #expect(thresholds.maximumDerivativeDepth == 3)
    }

    @Test("Relaxed thresholds lower the range size floor")
    func relaxedThresholds() {
        let thresholds = CGSSubdivisionThresholds.relaxed
        #expect(thresholds.minimumRangeSize == 2)
        #expect(thresholds.maximumDerivativeDepth == 10)
    }

    @Test("Custom thresholds store provided values")
    func customThresholds() {
        let thresholds = CGSSubdivisionThresholds(minimumRangeSize: 500, maximumDerivativeDepth: 5)
        #expect(thresholds.minimumRangeSize == 500)
        #expect(thresholds.maximumDerivativeDepth == 5)
    }
}
