//
//  ProbeBudget.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/2/2026.
//

struct ProbeBudget {
    let passName: String
    let limit: Int
    private(set) var consumed: Int = 0

    init(passName: String, limit: Int) {
        self.passName = passName
        self.limit = max(0, limit)
    }

    var remaining: Int {
        max(0, limit - consumed)
    }

    var isExhausted: Bool {
        consumed >= limit
    }

    var exhaustionReason: String {
        "\(passName) probe budget exhausted after \(consumed)/\(limit) materialization attempts."
    }

    mutating func consume() -> Bool {
        guard consumed < limit else {
            return false
        }
        consumed += 1
        return true
    }
}
