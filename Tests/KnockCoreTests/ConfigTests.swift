import XCTest
@testable import KnockCore

final class ConfigTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-test-\(UUID().uuidString).json")
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let config = KnockConfig(
            sensitivity: 0.5,
            windowMs: 300,
            mappings: ["2": ActionConfig(type: .mute, command: nil)]
        )
        try ConfigStore.save(config, to: url)
        let loaded = try ConfigStore.load(from: url)
        XCTAssertEqual(loaded, config)
    }

    func testShellCommandMappingRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let config = KnockConfig(
            sensitivity: 0.35,
            windowMs: 400,
            mappings: ["3": ActionConfig(type: .shellCommand, command: "open -a Notes")]
        )
        try ConfigStore.save(config, to: url)
        let loaded = try ConfigStore.load(from: url)
        XCTAssertEqual(loaded.mappings["3"]?.command, "open -a Notes")
    }

    func testWatcherFiresOnFileChange() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try ConfigStore.save(.default, to: url)

        let expectation = expectation(description: "watcher fires")
        var received: KnockConfig?
        let watcher = ConfigWatcher(url: url) { newConfig in
            received = newConfig
            expectation.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        // give the watcher a moment to attach before we write
        Thread.sleep(forTimeInterval: 0.2)
        var changed = KnockConfig.default
        changed.sensitivity = 0.9
        try ConfigStore.save(changed, to: url)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(received?.sensitivity, 0.9)
    }
}
