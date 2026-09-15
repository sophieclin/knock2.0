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

    func testKeystrokeMappingRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var config = KnockConfig.default
        config.mappings["3"] = ActionConfig(type: .keystroke, keys: "cmd+shift+4")
        try ConfigStore.save(config, to: url)
        XCTAssertEqual(try ConfigStore.load(from: url), config)
    }

    /// Config files written before `keys` existed must still load.
    func testLoadsConfigWithoutKeysField() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        {"sensitivity": 0.08, "windowMs": 400, "mappings": {"2": {"type": "mute"}}}
        """
        try Data(legacy.utf8).write(to: url)
        let loaded = try ConfigStore.load(from: url)
        XCTAssertEqual(loaded.mappings["2"], ActionConfig(type: .mute))
    }

    func testOpenAppMappingRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var config = KnockConfig.default
        config.mappings["4"] = ActionConfig(type: .openApp, app: "Claude")
        try ConfigStore.save(config, to: url)
        XCTAssertEqual(try ConfigStore.load(from: url), config)
    }

    func testEnabledDefaultsToTrueWhenMissingFromFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        {"sensitivity": 0.08, "windowMs": 400, "mappings": {}}
        """
        try Data(legacy.utf8).write(to: url)
        XCTAssertTrue(try ConfigStore.load(from: url).enabled)
    }

    func testEnabledFalseRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var config = KnockConfig.default
        config.enabled = false
        try ConfigStore.save(config, to: url)
        XCTAssertFalse(try ConfigStore.load(from: url).enabled)
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

    /// ConfigStore.save writes atomically (write temp + rename), which
    /// replaces the inode. The watcher must survive that and keep seeing
    /// subsequent saves, not just the first one.
    func testWatcherKeepsFiringAcrossAtomicRewrites() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try ConfigStore.save(.default, to: url)

        let first = expectation(description: "first change")
        let second = expectation(description: "second change")
        var sensitivities: [Double] = []
        let watcher = ConfigWatcher(url: url) { newConfig in
            sensitivities.append(newConfig.sensitivity)
            if sensitivities.count == 1 { first.fulfill() }
            if sensitivities.count == 2 { second.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        var changed = KnockConfig.default
        changed.sensitivity = 0.7
        try ConfigStore.save(changed, to: url)
        wait(for: [first], timeout: 2.0)

        Thread.sleep(forTimeInterval: 0.2)
        changed.sensitivity = 0.8
        try ConfigStore.save(changed, to: url)
        wait(for: [second], timeout: 2.0)

        XCTAssertEqual(sensitivities.suffix(1), [0.8])
    }

    /// knockd runs under sudo, where HOME is /var/root. It must still
    /// resolve the config path against the *invoking* user's home so it
    /// reads the same file KnockAgent writes.
    func testDefaultPathHonorsSudoUser() {
        let plain = ConfigStore.defaultPath(environment: [:])
        let sudo = ConfigStore.defaultPath(environment: ["SUDO_USER": NSUserName()])
        XCTAssertEqual(sudo, plain)
        XCTAssertTrue(plain.path.hasSuffix("/Library/Application Support/KnockDetector/config.json"))
    }

    func testDefaultPathFallsBackWhenSudoUserIsUnknown() {
        let plain = ConfigStore.defaultPath(environment: [:])
        let bogus = ConfigStore.defaultPath(environment: ["SUDO_USER": "no-such-user-\(UUID().uuidString)"])
        XCTAssertEqual(bogus, plain)
    }
}
