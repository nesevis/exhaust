import Foundation

/// Keeps runtime publication and command collection on the same wire layout.
package enum CampaignWire {
    package static let reportDirectoryKey = "EXHAUST_REPORT_DIR"
    package static let stateDirectoryKey = "EXHAUST_STATE_DIR"
    package static let budgetKey = "EXHAUST_EXPLORE_TIME_NS"
    package static let resumeKey = "EXHAUST_RESUME"
    package static let eventsDirectory = "events"
    package static let reportFilename = "report.json"
    package static let streamFilename = "events.jsonl"

    /// Zero-pads the sequence to eight digits so a lexical directory listing sorts a campaign's spool files in publication order.
    package static func eventID(campaignID: String, sequence: Int) -> String {
        let digits = String(sequence)
        return "\(campaignID)-" + String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    package static func jsonURL(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}
