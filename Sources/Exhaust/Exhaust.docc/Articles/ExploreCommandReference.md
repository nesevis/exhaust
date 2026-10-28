# Explore command reference

Read the machine-readable reports, event stream, and recovery stores the `explore` command writes.

## Overview

<doc:CoverageGuidedFuzzing> covers running a campaign and reading its terminal report. This article describes what the `explore` command leaves on disk for CI systems and tools: where each file goes, what the JSON reports and event stream contain, how findings are identified across runs, and how recovery stores are kept apart.

## Output layout

By default the command writes into its build workspace under `.build/plugins` and prints the build, attachment, and crash-recovery directories it uses. With `--output <path>`, the layout is:

| Path | Contents |
|---|---|
| `<path>/report.json` | The primary report for the most recent command run. |
| `<path>/events.jsonl` | The live event stream for that run. |
| `<path>/attachments/<run-id>/` | Summary and cluster attachments, plus per-campaign records. |
| `<path>/state/<build-id>/` | Crash-recovery checkpoints. |

The build ID separates configurations, instrumented targets, compilers, and coverage recorders, so each combination has its own build and default recovery directory. Build products stay in SwiftPM's plugin workspace. A lock stops overlapping commands from using the same build.

### Attachment names

Each completed campaign records a summary attachment and one attachment per failure cluster. Their names share a prefix built from the test name (including enclosing suites), the seed the search actually ran with, and, under the `explore` command, a unique campaign ID:

```
explore-time-decoderAcceptsEveryMessage-seed-3-<campaign-id>-summary.txt
explore-time-decoderAcceptsEveryMessage-seed-3-<campaign-id>-cluster-1.txt
```

The campaign ID tells repeated calls apart, including calls with the same test name and seed. Direct test runs outside the command omit it. Names are sanitised and shortened for the file system, and Swift Testing adds a suffix if a name still repeats. Without a Swift Testing context, the test-name component is `standalone`.

## JSON reports

Every command run writes `report.json` and `events.jsonl` directly in the output root.

`--xunit` passes `--xunit-output <path>/xunit.xml` to SwiftPM, which may write `xunit.xml`, `xunit-swift-testing.xml`, or both, depending on the test frameworks that ran. The JSON's `xunitFiles` lists the files actually produced and is empty by default.

### XML and JSON describe different things

The native XML describes Swift tests. On Swift 6.4, a parameterised function has one `<testcase>` for all its argument cases, so individual argument cases are not separate entries or structured fields. Several `#explore` calls in one function also share that entry. The XML keeps a failed assertion's expression but omits the failing seed value. Multiple reported issues appear as multiple `<failure>` elements under the shared entry. Exhaust passes SwiftPM's XML through unchanged.

The JSON describes individual campaigns. Two tests with two `#explore` calls each produce four `campaigns` entries, while the XML contains two test entries. Repeated calls at the same source location remain separate entries.

### Campaign entries

Each entry in `campaigns` has:

- A unique `id`, plus the Swift Testing `testID` and `testName` when available.
- The macro's source location and entry-point kind.
- Declared and effective budgets (`declaredBudgetSeconds`, `effectiveBudgetSeconds`).
- The checkpoint path.
- The actual `seed`, generated when no replay seed was supplied, and `requestedSeed` when one was supplied. The resolved seed appears in the start record and survives an interruption. Invalid settings can prevent seed generation. Seeds are decimal strings, so JSON consumers do not lose `UInt64` precision.

A completed campaign also carries its report:

- Attempt and invocation counts, including `judged`, the evaluated inputs the property passed or failed.
- Corpus size and coverage statistics. Coverage stays per campaign, and edge counts are not summed across campaigns.
- Timings, the stopping reason, and whether the run resumed a predecessor.
- Reduced failure clusters with their suspect locations.
- Reproduction settings and attachment paths relative to the output root.

Corpus contents stay in the recovery checkpoints and are not copied into the report.

### The top-level record

`schemaVersion: 1` identifies the format. The top-level record includes the command's configuration, coverage recorder, instrumented targets, test selection, execution status, and counts by campaign outcome.

Command status (`running`, `succeeded`, or `failed`) and campaign outcome (`passed`, `failed`, `skipped`, or `error`) are separate. Missing instrumentation, for example, is a skipped campaign even when Swift Testing only emitted a warning and the command succeeded. Suppressed or expected test issues can likewise differ from campaign findings. `issuesSuppressed` records Exhaust's suppression setting, while the command's exit status reflects SwiftPM's verdict. The optional XML carries the test framework's per-test results.

### How the report survives a crash

Each invocation writes a start record under `attachments/<run-id>/campaigns/` and replaces it atomically with its completed result. These records are written even under `.suppress(.attachments)`.

After the test process exits, including after a crash or failure, the command collects the run's records into `report.json`. Unfinished invocations are marked `interrupted`, and completed findings remain available. Tests that never reached `#explore` have no campaign entry. If the command itself is killed before it finishes, the aggregate may still say `running`, but the individual records remain. A failure to write reporting data fails the test or command, so results are never dropped silently.

A new command run replaces the root aggregate and event stream and clears its previous XML files, while keeping earlier attachment directories. Commands sharing an output root are locked against concurrent writes. A build or setup failure after the report is initialised still leaves a failed aggregate, possibly with no campaigns or XML.

## Stable finding identifiers

Each entry in `campaigns[].report.clusters` has a campaign-local numeric `id` and a stable string `findingID`, such as `finding-v1-5567b98ffa24a3fd`. Matching reduced findings share a `findingID` across seeds and reruns, whereas the campaign's UUID `id` identifies one invocation. The same finding can appear in several campaigns without their budgets or results being merged.

The identifier is a fingerprint of the enclosing test ID, the macro's file ID, line, and column, the entry-point kind, and the canonical reduced choices. The reduced choices exclude metadata that varies between reduction paths. Nothing else contributes: seed, campaign UUID, discovery order, counters, timestamps, rendered descriptions, symptoms, and coverage addresses are all excluded.

Like the terminal report, the identifier names a reduced form rather than a root cause, and one form can collect several symptoms. Moving the test or call site, changing the generator's structure, or reaching a different reduced form can change the ID. The string has no documented internal structure, and `finding-v1` names the version of the identity algorithm. Failures that could not be reduced have symptom counts but no finding IDs.

## Live event stream

Each complete line of `events.jsonl` is one JSON object with these fields:

- `schemaVersion: 1`, `runID`, and a unique `eventID`.
- A zero-based `sequence`, which gives collection order rather than wall-clock order between parallel campaigns.
- `type`, a Unix `timestamp` in seconds, and `payload`.
- For campaign events, `campaignID`. Runtime events also carry a zero-based `campaignSequence`, and each campaign's events keep their own publication order.

When consuming the stream, check `schemaVersion` and ignore unrecognised fields and event types.

| Event type | Payload |
|---|---|
| `run.started` | Primary `reportPath`. |
| `run.phaseChanged` | `phase`: preparing, building, or testing. |
| `campaign.started` | Test and source identity, resolved `seed`, `requestedSeed` when supplied, budgets, checkpoint path, and `recordPath`. |
| `finding.reported` | Finalised `finding`, including `findingID`, actual `seed`, test and source identity, kind, and `recordPath`. |
| `campaign.finished` | Completed campaign record, including outcome, detailed report, and paths relative to the output root. |
| `campaign.interrupted` | An unfinished campaign identified after the test process exits. |
| `run.finished` | Command status, campaign totals, reporting errors, `reportPath`, and child exit or error details when available. |

The command publishes campaign starts and completions while tests run, polling roughly every 100 ms. **Finding events arrive when their campaign completes**, after reduction and classification, so they are not notifications of raw failures as they happen. There are no per-attempt or checkpoint events. A single writer collects atomic files from `attachments/<run-id>/campaigns/events/`, so lines from parallel campaigns or test processes never interleave. `.suppress(.attachments)` and `.suppress(.logs)` do not suppress structured reports or events.

`report.json` is the authoritative final snapshot. After a test-process crash, the command still collects published events, marks running campaigns interrupted, and finalises the report. If the command itself is killed, `run.finished` may be missing and the last line may be incomplete. Read complete lines only, and inspect the retained campaign records and spool files. A crashed campaign may have checkpointed findings that never became finding events. Errors collecting the stream appear in `reportingErrors` and fail the command.

## Recovery stores

Exhaust keeps each campaign's checkpoints in a store identified by the enclosing Swift Testing test, the macro's file, line, and column, and the resolved seed. The seed is generated when `.replay` is omitted. Concurrent invocations at one call site therefore have separate stores without caller-supplied seeds.

An unseeded rerun looks for an abandoned checkpoint from the same test and call site. Exhaust skips locked stores, locks an available predecessor, and moves its checkpoint and breadcrumb into the new run's seed directory before searching. Each invocation recovers at most one predecessor. The move prevents two runs from recovering the same checkpoint. An explicit `.replay(seed)` reads only the checkpoint for that seed.

An ownership lock stops two runs from writing the same store at once, including across processes. Replays of the same seed at one call site must run serially, or use separate recovery directories with `--output` (`EXHAUST_STATE_DIR` for direct test runs). The operating system releases ownership when a process ends.

`EXHAUST_RESUME=0` skips reading predecessor state but keeps checkpoint writes and ownership checks. Empty ownership files in the sibling `.locks` directory are kept after release, including when instrumentation is missing, so that concurrent processes always lock the same file. They contain no recovery data. Invalid replay settings and time budgets are rejected before these files are created.
