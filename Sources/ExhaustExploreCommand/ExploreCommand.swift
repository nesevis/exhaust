import ArgumentParser

@main
struct ExploreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift package",
        abstract: "Run coverage-guided fuzzing campaigns.",
        subcommands: [ExploreCampaign.self]
    )
}

// MARK: - Campaign Command

private struct ExploreCampaign: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explore",
        abstract: "Build selected root targets with coverage instrumentation and run tests.",
        discussion: """
        Instrumentation uses an ephemeral manifest overlay; Package.swift is never edited.
        The selected test target is instrumented too. Dependencies retain their own settings.
        Builds and attachments are saved in the plugin work directory. Tests' own time limits still apply.

        SwiftPM options such as --package-path and --scratch-path go before explore.
        """
    )

    @OptionGroup var options: Options

    mutating func run() throws {
        do {
            try CommandRunner(options: options).run()
        } catch let failure as ChildFailure {
            throw ExitCode(failure.status)
        }
    }
}
