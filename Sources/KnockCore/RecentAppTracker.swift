/// Remembers which app was frontmost before the current one, so a tap can
/// switch back to it. Fed by NSWorkspace activation notifications in
/// KnockAgent; kept free of AppKit here so the history logic is testable.
public struct RecentAppTracker {
    private let ownPID: Int32
    private var currentPID: Int32?
    public private(set) var previousPID: Int32?

    public init(ownPID: Int32) {
        self.ownPID = ownPID
    }

    public mutating func noteActivated(pid: Int32) {
        guard pid != ownPID, pid != currentPID else { return }
        previousPID = currentPID
        currentPID = pid
    }
}
