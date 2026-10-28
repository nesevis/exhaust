import ExhaustCore
import ExhaustSupport

extension FuzzCampaignKind {
    init(mode: SearchableExecutionModel) {
        self = switch mode {
            case .sequential:
                .stateMachineSequential
            case .tasks:
                .stateMachineTasks
        }
    }
}

extension CampaignOutcome {
    init(_ outcome: FuzzReport.Outcome) {
        self = switch outcome {
            case .passed:
                .passed
            case .failed:
                .failed
            case .skipped:
                .skipped
            case .error:
                .error
        }
    }
}
