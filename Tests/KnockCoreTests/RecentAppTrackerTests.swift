import XCTest
@testable import KnockCore

final class RecentAppTrackerTests: XCTestCase {
    func testNoPreviousAppBeforeTwoDistinctActivations() {
        var tracker = RecentAppTracker(ownPID: 1)
        XCTAssertNil(tracker.previousPID)
        tracker.noteActivated(pid: 100)
        XCTAssertNil(tracker.previousPID)
    }

    func testPreviousIsTheAppBeforeTheCurrentOne() {
        var tracker = RecentAppTracker(ownPID: 1)
        tracker.noteActivated(pid: 100)
        tracker.noteActivated(pid: 200)
        XCTAssertEqual(tracker.previousPID, 100)
        tracker.noteActivated(pid: 300)
        XCTAssertEqual(tracker.previousPID, 200)
    }

    func testReactivatingCurrentAppDoesNotShiftHistory() {
        var tracker = RecentAppTracker(ownPID: 1)
        tracker.noteActivated(pid: 100)
        tracker.noteActivated(pid: 200)
        tracker.noteActivated(pid: 200)
        XCTAssertEqual(tracker.previousPID, 100)
    }

    /// Opening the menu bar window can activate KnockAgent itself; that must
    /// not count as "the app the user was just in".
    func testOwnProcessIsIgnored() {
        var tracker = RecentAppTracker(ownPID: 1)
        tracker.noteActivated(pid: 100)
        tracker.noteActivated(pid: 200)
        tracker.noteActivated(pid: 1)
        XCTAssertEqual(tracker.previousPID, 100)
    }
}
