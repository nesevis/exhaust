import Testing
import Exhaust
import ExhaustCore
import Foundation

@Suite("SCA sequence length benchmark", .serialized, .disabled("Manual benchmark — enable to measure"))
struct SCABenchmark {
    @Test("Sequence length timing", arguments: [5, 8, 10, 15, 20, 25, 30])
    func sequenceLengthTiming(length: Int) {
        let cap: Int
        switch length {
        case ...6:  cap = 6
        case ...8:  cap = 5
        case ...12: cap = 4
        case ...20: cap = 3
        default:    cap = 2
        }
        var times: [Duration] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let _ = #exhaust(
                BuggyCounterSpec.self,
                commandLimit: length,
                .suppressIssueReporting,
            )
            times.append(ContinuousClock.now - start)
        }
        let median = times.sorted()[2]
        print("seqLen=\(String(format: "%2d", length)) (t≤\(cap)): \(median)")
    }
}
