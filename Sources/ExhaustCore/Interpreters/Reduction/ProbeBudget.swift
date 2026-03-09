//
//  ProbeBudget.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/2/2026.
//

public struct ProbeBudget {
    public let passName: String
    public let limit: Int
    public private(set) var consumed: Int = 0

    public init(passName: String, limit: Int) {
        self.passName = passName
        self.limit = max(0, limit)
    }

    public var remaining: Int {
        max(0, limit - consumed)
    }

    public var isExhausted: Bool {
        consumed >= limit
    }

    public var exhaustionReason: String {
        "\(passName) probe budget exhausted after \(consumed)/\(limit) materialization attempts."
    }

    public mutating func consume() -> Bool {
        guard consumed < limit else {
            return false
        }
        consumed += 1
        return true
    }
}
