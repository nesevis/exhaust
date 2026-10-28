import ExhaustCore
@testable import Exhaust

extension __ExhaustRuntime {
    /// Resolves `time` and `settings` through a campaign context, as the entry points do, then runs the resolved core without reserving persistence or recording a campaign. A rejected configuration returns the same report ``FuzzCampaign/search(core:replay:)`` would.
    static func runExploreTimeCore<Output>(
        gen: Generator<Output>,
        generatorIsReflective: Bool = true,
        time: TimeSpan,
        settings: [PropertyFuzzSettings],
        source coverage: CoverageSourceSelection,
        configure: ((inout FuzzRunnerConfiguration) -> Void)?,
        hooks: FuzzHooks<Output>? = nil,
        persistence: FuzzPersistenceContext? = nil,
        property: @escaping @Sendable (Output) -> FuzzVerdict
    ) -> FuzzReport {
        let parsed = ParsedPropertyFuzzSettings(settings)
        let context = FuzzCampaignContext.resolve(
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column,
            seed: parsed.seed,
            kind: .value,
            time: time,
            invalidReplayMessage: parsed.invalidReplayMessage
        )
        switch context.runResolution {
            case let .rejected(report):
                return report
            case let .resolved(resolved):
                return runExploreTimeCore(
                    gen: gen,
                    generatorIsReflective: generatorIsReflective,
                    resolved: resolved,
                    settings: parsed,
                    source: coverage,
                    configure: configure,
                    hooks: hooks,
                    persistence: persistence,
                    property: property
                )
        }
    }
}
