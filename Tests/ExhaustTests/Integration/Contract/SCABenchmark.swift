import Exhaust
import Foundation
import Testing

@Suite("SCA sequence length benchmark", .serialized)
struct SCABenchmark {
    @Test("Sequence length timing", arguments: [5, 8, 10, 15, 20, 25, 30])
    func sequenceLengthTiming(length: Int) {
        let cap = switch length {
        case ...6: 6
        case ...8: 5
        case ...12: 4
        case ...20: 3
        default: 2
        }
        var times: [Duration] = []
        for _ in 0 ..< 5 {
            let start = ContinuousClock.now
            _ = #exhaust(
                BuggyCounterSpec.self,
                commandLimit: length,
                .suppress(.issueReporting)
            )
            times.append(ContinuousClock.now - start)
        }
        let median = times.sorted()[2]
        print("seqLen=\(String(format: "%2d", length)) (t≤\(cap)): \(median)")
    }
}
