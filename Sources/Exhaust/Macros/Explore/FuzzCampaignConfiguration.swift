import Foundation

/// Captures validation and the chosen run seed once, before checkpoint reservation or a thread hop.
package struct FuzzCampaignConfiguration: Sendable {
    package let declaredBudgetSeconds: Double
    package let resolution: Result<ResolvedFuzzRun, InvalidFuzzConfiguration>

    package init(
        time: TimeSpan,
        seed: UInt64?,
        propertyModule: String,
        invalidReplayMessage: String? = nil,
        environment: [String: String]
    ) {
        declaredBudgetSeconds = time.seconds
        if let invalidReplayMessage {
            resolution = .failure(InvalidFuzzConfiguration(message: invalidReplayMessage))
            return
        }
        do {
            let budget = try __ExhaustRuntime.resolvedExploreBudget(declared: time, environment: environment)
            resolution = .success(ResolvedFuzzRun(
                seed: seed ?? UInt64.random(in: .min ... .max),
                budgetNanoseconds: budget,
                propertyModule: propertyModule
            ))
        } catch {
            resolution = .failure(InvalidFuzzConfiguration(message: error.message))
        }
    }

    package var budgetSeconds: Double? {
        guard case let .success(resolved) = resolution else {
            return nil
        }
        return Double(resolved.budgetNanoseconds) / 1_000_000_000
    }
}

/// Supplies the core with validated values without another environment read or random seed draw.
package struct ResolvedFuzzRun: Sendable {
    package let seed: UInt64
    package let budgetNanoseconds: UInt64
    /// The module of the `#explore` call site, which holds the property closure. The explore command instruments the test target, so the closure's own edges discriminate failures; the report ranks them after every other suspect.
    package let propertyModule: String
}

/// Describes any rejected campaign setting, including replay seeds and time budgets.
package struct InvalidFuzzConfiguration: Error, Equatable {
    package let message: String
}
