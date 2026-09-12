import XCTest
@testable import KnockCore

final class ActionRunnerTests: XCTestCase {
    final class FakeExecutor: ActionExecuting {
        var muteCalled = false
        var playPauseCalled = false
        var lastCommand: String?
        var previousAppCalled = false

        func mute() throws { muteCalled = true }
        func mediaPlayPause() throws { playPauseCalled = true }
        func runShellCommand(_ command: String) throws { lastCommand = command }
        func switchToPreviousApp() throws { previousAppCalled = true }
    }

    func testDispatchesMute() throws {
        let fake = FakeExecutor()
        try ActionRunner(executor: fake).run(ActionConfig(type: .mute))
        XCTAssertTrue(fake.muteCalled)
    }

    func testDispatchesPreviousApp() throws {
        let fake = FakeExecutor()
        try ActionRunner(executor: fake).run(ActionConfig(type: .previousApp))
        XCTAssertTrue(fake.previousAppCalled)
    }

    func testDispatchesMediaPlayPause() throws {
        let fake = FakeExecutor()
        try ActionRunner(executor: fake).run(ActionConfig(type: .mediaPlayPause))
        XCTAssertTrue(fake.playPauseCalled)
    }

    func testDispatchesShellCommandWithItsArgument() throws {
        let fake = FakeExecutor()
        try ActionRunner(executor: fake).run(ActionConfig(type: .shellCommand, command: "echo hi"))
        XCTAssertEqual(fake.lastCommand, "echo hi")
    }

    func testShellCommandWithoutCommandStringIsANoOp() throws {
        let fake = FakeExecutor()
        try ActionRunner(executor: fake).run(ActionConfig(type: .shellCommand, command: nil))
        XCTAssertNil(fake.lastCommand)
    }
}
