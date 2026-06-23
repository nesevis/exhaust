/// Assigns a command to a scheduling lane in a concurrent contract test.
///
/// During generation, the marker generator produces values in 0...N (where N is the concurrency level). The reducer's value-minimization pass drives markers toward 0 (prefix), naturally discovering which commands must remain concurrent to reproduce the failure. Commands whose markers reach prefix move to the sequential phase, proving they are not part of the minimal concurrent counterexample.
///
/// Value 0 is the sequential prefix. Values 1 through N map to lanes "a" through the Nth letter.
package struct ScheduleMarker: RawRepresentable, Sendable, Equatable, Hashable, CustomStringConvertible {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The sequential prefix marker. Commands with this marker run before any interleaving begins.
    package static let prefix = ScheduleMarker(rawValue: 0)

    /// Whether this marker assigns to the sequential prefix rather than a concurrent lane.
    package var isPrefix: Bool {
        rawValue == 0
    }

    /// The zero-based lane index, or nil if this is the prefix marker.
    package var laneIndex: UInt8? {
        rawValue > 0 ? rawValue - 1 : nil
    }

    package var description: String {
        if rawValue == 0 { return "prefix" }
        let index = rawValue - 1
        if index < 26 { return String(UnicodeScalar(UInt8(ascii: "a") + index)) }
        return "lane\(index)"
    }
}
