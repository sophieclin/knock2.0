/// Performs the side-effecting half of an action. Implemented by
/// SystemActionExecutor (KnockAgent target) for real use, and by a fake
/// in tests, so ActionRunner's dispatch logic is testable without
/// touching CoreAudio/AppKit/Process.
public protocol ActionExecuting {
    func mute() throws
    func mediaPlayPause() throws
    func runShellCommand(_ command: String) throws
    func switchToPreviousApp() throws
    func pressKeys(_ combo: KeyCombo) throws
}

public final class ActionRunner {
    private let executor: ActionExecuting

    public init(executor: ActionExecuting) {
        self.executor = executor
    }

    public func run(_ action: ActionConfig) throws {
        switch action.type {
        case .mute:
            try executor.mute()
        case .mediaPlayPause:
            try executor.mediaPlayPause()
        case .shellCommand:
            guard let command = action.command else { return }
            try executor.runShellCommand(command)
        case .previousApp:
            try executor.switchToPreviousApp()
        case .keystroke:
            guard let keys = action.keys, let combo = KeyCombo.parse(keys) else { return }
            try executor.pressKeys(combo)
        }
    }
}
