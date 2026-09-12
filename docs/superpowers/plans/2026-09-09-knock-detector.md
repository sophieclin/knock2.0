# Knock Detector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a personal, free alternative to the Knock app: detect tap patterns on the MacBook chassis via the internal accelerometer and trigger mute / media play-pause / arbitrary shell commands.

**Architecture:** Two Swift executables sharing a `KnockCore` library. `knockd` (runs as root, started manually via `sudo`) reads the accelerometer through IOKit HID, detects tap patterns, and broadcasts tap-count events over a Unix domain socket. `KnockAgent` (runs as the normal user) owns the settings UI and config file, listens on that socket, and executes the mapped action.

**Tech Stack:** Swift 5.9+, Swift Package Manager, IOKit (HID), CoreAudio, AppKit/SwiftUI (`MenuBarExtra`, macOS 13+), XCTest.

**Spec:** [docs/superpowers/specs/2026-09-08-knock-detector-design.md](../specs/2026-09-08-knock-detector-design.md)

## Global Constraints

- Target macOS 13+ (for `MenuBarExtra`), Apple Silicon only (tested config: M3).
- Accelerometer device: IOKit usage page `0xFF00`, usage `3`, under `AppleSPUHIDDevice`. Reports are 22 bytes; X/Y/Z are little-endian `Int32` at byte offsets 6/10/14, units of 1/65536 g.
- Reading the accelerometer requires root — `knockd` must be run with `sudo`.
- Socket path: `/tmp/knockd.sock` (Unix domain socket, line protocol: ASCII decimal tap count + `\n`).
- No auto-start/LaunchDaemon in this plan (explicitly deferred in the spec's Future Work).

---

## Task 1: Project scaffolding

**Files:**
- Create: `Package.swift`
- Create: `Sources/KnockCore/.gitkeep` (placeholder so the empty target has a directory — removed once Task 2 adds real files)
- Create: `Sources/knockd/main.swift`
- Create: `Sources/KnockAgent/main.swift`
- Create: `Tests/KnockCoreTests/.gitkeep`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a buildable SwiftPM package with four targets (`KnockCore`, `knockd`, `KnockAgent`, `KnockCoreTests`) that later tasks add real code to.

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Knock",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "KnockCore"),
        .executableTarget(name: "knockd", dependencies: ["KnockCore"]),
        .executableTarget(name: "KnockAgent", dependencies: ["KnockCore"]),
        .testTarget(name: "KnockCoreTests", dependencies: ["KnockCore"]),
    ]
)
```

- [ ] **Step 2: Create placeholder source files so the package builds**

`Sources/KnockCore/.gitkeep` — empty file.

`Sources/knockd/main.swift`:
```swift
print("knockd placeholder")
```

`Sources/KnockAgent/main.swift`:
```swift
print("KnockAgent placeholder")
```

`Tests/KnockCoreTests/.gitkeep` — empty file.

- [ ] **Step 3: Verify the package builds**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "Scaffold SwiftPM package with knockd, KnockAgent, KnockCore targets"
```

---

## Task 2: KnockCore — TapDetector

**Files:**
- Create: `Sources/KnockCore/TapDetector.swift`
- Test: `Tests/KnockCoreTests/TapDetectorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct AccelSample { timestamp: TimeInterval, x: Double, y: Double, z: Double }` and `public final class TapDetector { init(sensitivity: Double, windowSeconds: TimeInterval); func ingest(_ sample: AccelSample) -> Int? }`. Later tasks (7, 8) feed real accelerometer samples into `ingest`.

- [ ] **Step 1: Write the failing tests**

`Tests/KnockCoreTests/TapDetectorTests.swift`:
```swift
import XCTest
@testable import KnockCore

final class TapDetectorTests: XCTestCase {
    func testSingleTapDetected() {
        let detector = TapDetector(sensitivity: 0.3, windowSeconds: 0.4)
        var t = 0.0
        for _ in 0..<5 {
            _ = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.0))
            t += 0.01
        }
        _ = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.5))
        t += 0.51
        let result = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.0))
        XCTAssertEqual(result, 1)
    }

    func testTwoTapsGroupedIntoOnePattern() {
        let detector = TapDetector(sensitivity: 0.3, windowSeconds: 0.4)
        var t = 0.0
        for _ in 0..<5 {
            _ = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.0))
            t += 0.01
        }
        _ = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.5))
        t += 0.1
        _ = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.5))
        t += 0.51
        let result = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.0))
        XCTAssertEqual(result, 2)
    }

    func testSmallVibrationBelowThresholdIgnored() {
        let detector = TapDetector(sensitivity: 0.3, windowSeconds: 0.4)
        var t = 0.0
        var lastResult: Int? = nil
        for _ in 0..<20 {
            lastResult = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.05))
            t += 0.01
        }
        XCTAssertNil(lastResult)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TapDetectorTests`
Expected: FAIL — `TapDetector`/`AccelSample` not defined.

- [ ] **Step 3: Implement `TapDetector`**

`Sources/KnockCore/TapDetector.swift`:
```swift
import Foundation

public struct AccelSample {
    public let timestamp: TimeInterval
    public let x: Double
    public let y: Double
    public let z: Double

    public init(timestamp: TimeInterval, x: Double, y: Double, z: Double) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Detects tap-count patterns from a continuous stream of accelerometer samples.
/// A "hit" is a magnitude deviation from the rolling gravity baseline that
/// crosses `sensitivity`. Hits arriving within `windowSeconds` of each other
/// are grouped into one pattern; the pattern is reported (as its hit count)
/// once a sample arrives more than `windowSeconds` after the last hit.
public final class TapDetector {
    public var sensitivity: Double
    public var windowSeconds: TimeInterval

    private var runningAverage: Double = 1.0 // starts near 1g at rest
    private let averageAlpha: Double = 0.02
    private let debounceSeconds: TimeInterval = 0.06
    private var hitsInBurst: [TimeInterval] = []
    private var lastHitTime: TimeInterval?

    public init(sensitivity: Double = 0.35, windowSeconds: TimeInterval = 0.4) {
        self.sensitivity = sensitivity
        self.windowSeconds = windowSeconds
    }

    /// Feed one sample. Returns the completed tap count if this sample's
    /// arrival closes out a previous burst (i.e. more than `windowSeconds`
    /// have passed since the last hit), otherwise nil.
    public func ingest(_ sample: AccelSample) -> Int? {
        let magnitude = (sample.x * sample.x + sample.y * sample.y + sample.z * sample.z).squareRoot()
        let deviation = abs(magnitude - runningAverage)
        runningAverage = runningAverage * (1 - averageAlpha) + magnitude * averageAlpha

        var completed: Int? = nil
        if let last = lastHitTime, sample.timestamp - last > windowSeconds, !hitsInBurst.isEmpty {
            completed = hitsInBurst.count
            hitsInBurst.removeAll()
            lastHitTime = nil
        }

        if deviation > sensitivity {
            if lastHitTime == nil || sample.timestamp - lastHitTime! > debounceSeconds {
                hitsInBurst.append(sample.timestamp)
                lastHitTime = sample.timestamp
            }
        }

        return completed
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TapDetectorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/KnockCore/TapDetector.swift Tests/KnockCoreTests/TapDetectorTests.swift
git commit -m "Add TapDetector: groups accelerometer hits into tap-count patterns"
```

---

## Task 3: KnockCore — AccelReportParser

**Files:**
- Create: `Sources/KnockCore/AccelReportParser.swift`
- Test: `Tests/KnockCoreTests/AccelReportParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum AccelReportParser { static func parse(_ bytes: [UInt8]) -> (x: Double, y: Double, z: Double)? }`. Task 7's `AccelerometerReader` calls this to turn raw HID report bytes into values it wraps as `AccelSample`.

- [ ] **Step 1: Write the failing test**

`Tests/KnockCoreTests/AccelReportParserTests.swift`:
```swift
import XCTest
@testable import KnockCore

final class AccelReportParserTests: XCTestCase {
    /// Builds a 22-byte report with the given raw int32 (already in 1/65536 g units)
    /// little-endian at offsets 6 (x), 10 (y), 14 (z).
    private func makeReport(xRaw: Int32, yRaw: Int32, zRaw: Int32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 22)
        func writeLE(_ value: Int32, at offset: Int) {
            let bits = UInt32(bitPattern: value)
            bytes[offset] = UInt8(bits & 0xFF)
            bytes[offset + 1] = UInt8((bits >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((bits >> 16) & 0xFF)
            bytes[offset + 3] = UInt8((bits >> 24) & 0xFF)
        }
        writeLE(xRaw, at: 6)
        writeLE(yRaw, at: 10)
        writeLE(zRaw, at: 14)
        return bytes
    }

    func testParsesOneGOnZAxis() {
        let report = makeReport(xRaw: 0, yRaw: 0, zRaw: 65536) // 65536 / 65536 = 1.0g
        let result = AccelReportParser.parse(report)
        XCTAssertEqual(result?.x, 0.0)
        XCTAssertEqual(result?.y, 0.0)
        XCTAssertEqual(result?.z, 1.0)
    }

    func testParsesNegativeValues() {
        let report = makeReport(xRaw: -32768, yRaw: 0, zRaw: 0) // -0.5g
        let result = AccelReportParser.parse(report)
        XCTAssertEqual(result?.x, -0.5)
    }

    func testReturnsNilForTooShortReport() {
        let shortReport = [UInt8](repeating: 0, count: 10)
        XCTAssertNil(AccelReportParser.parse(shortReport))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AccelReportParserTests`
Expected: FAIL — `AccelReportParser` not defined.

- [ ] **Step 3: Implement `AccelReportParser`**

`Sources/KnockCore/AccelReportParser.swift`:
```swift
/// Parses raw IOKit HID input reports from the Apple Silicon internal
/// accelerometer (AppleSPUHIDDevice, vendor usage page 0xFF00, usage 3).
/// Reports are 22 bytes; X/Y/Z are little-endian Int32 at byte offsets
/// 6, 10, 14, in units of 1/65536 g. This layout comes from community
/// reverse-engineering (Apple does not document this device) — see the
/// design doc's Background section for sources.
public enum AccelReportParser {
    public static func parse(_ bytes: [UInt8]) -> (x: Double, y: Double, z: Double)? {
        guard bytes.count >= 18 else { return nil }

        func readInt32LE(at offset: Int) -> Int32 {
            let b0 = UInt32(bytes[offset])
            let b1 = UInt32(bytes[offset + 1]) << 8
            let b2 = UInt32(bytes[offset + 2]) << 16
            let b3 = UInt32(bytes[offset + 3]) << 24
            return Int32(bitPattern: b0 | b1 | b2 | b3)
        }

        let x = Double(readInt32LE(at: 6)) / 65536.0
        let y = Double(readInt32LE(at: 10)) / 65536.0
        let z = Double(readInt32LE(at: 14)) / 65536.0
        return (x, y, z)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AccelReportParserTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/KnockCore/AccelReportParser.swift Tests/KnockCoreTests/AccelReportParserTests.swift
git commit -m "Add AccelReportParser for raw 22-byte HID accelerometer reports"
```

---

## Task 4: KnockCore — Config, ConfigStore, ConfigWatcher

**Files:**
- Create: `Sources/KnockCore/Config.swift`
- Test: `Tests/KnockCoreTests/ConfigTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct ActionConfig: Codable, Equatable { public enum Kind: String, Codable { case mute, mediaPlayPause, shellCommand }; let type: Kind; let command: String? }`
  - `public struct KnockConfig: Codable, Equatable { var sensitivity: Double; var windowMs: Int; var mappings: [String: ActionConfig]; static let default: KnockConfig }`
  - `public enum ConfigStore { static var defaultPath: URL; static func load(from: URL) throws -> KnockConfig; static func save(_ : KnockConfig, to: URL) throws }`
  - `public final class ConfigWatcher { init(url: URL, onChange: @escaping (KnockConfig) -> Void); func start(); func stop() }`
  - Task 11's `AgentModel` uses all of the above; Task 8's `knockd` main.swift uses `ConfigStore`/`KnockConfig` to read `sensitivity`/`windowMs`.

- [ ] **Step 1: Write the failing tests**

`Tests/KnockCoreTests/ConfigTests.swift`:
```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests`
Expected: FAIL — `KnockConfig`/`ActionConfig`/`ConfigStore`/`ConfigWatcher` not defined.

- [ ] **Step 3: Implement `Config.swift`**

`Sources/KnockCore/Config.swift`:
```swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ActionConfig: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        case mute
        case mediaPlayPause
        case shellCommand
    }

    public let type: Kind
    public let command: String?

    public init(type: Kind, command: String? = nil) {
        self.type = type
        self.command = command
    }
}

public struct KnockConfig: Codable, Equatable {
    public var sensitivity: Double
    public var windowMs: Int
    public var mappings: [String: ActionConfig]

    public init(sensitivity: Double, windowMs: Int, mappings: [String: ActionConfig]) {
        self.sensitivity = sensitivity
        self.windowMs = windowMs
        self.mappings = mappings
    }

    public static let `default` = KnockConfig(
        sensitivity: 0.35,
        windowMs: 400,
        mappings: [
            "1": ActionConfig(type: .mediaPlayPause),
            "2": ActionConfig(type: .mute),
        ]
    )
}

public enum ConfigStore {
    public static var defaultPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Knock", isDirectory: true).appendingPathComponent("config.json")
    }

    public static func load(from url: URL) throws -> KnockConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(KnockConfig.self, from: data)
    }

    public static func save(_ config: KnockConfig, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }
}

/// Watches a config file for changes and reloads it, so KnockAgent's
/// settings UI and knockd's tuning parameters can be edited without
/// restarting either process.
public final class ConfigWatcher {
    private let url: URL
    private let onChange: (KnockConfig) -> Void
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?

    public init(url: URL, onChange: @escaping (KnockConfig) -> Void) {
        self.url = url
        self.onChange = onChange
    }

    public func start() {
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let config = try? ConfigStore.load(from: self.url) else { return }
            self.onChange(config)
        }
        source.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigTests`
Expected: PASS (3 tests). If `testWatcherFiresOnFileChange` is flaky, it's a timing issue with `Thread.sleep` — increase the sleep to 0.5s rather than removing the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnockCore/Config.swift Tests/KnockCoreTests/ConfigTests.swift
git commit -m "Add KnockConfig, ConfigStore, and ConfigWatcher"
```

---

## Task 5: KnockCore — SocketIPC (shared protocol)

**Files:**
- Create: `Sources/KnockCore/SocketIPC.swift`
- Test: `Tests/KnockCoreTests/SocketIPCTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum SocketIPC { static let socketPath: String; static func encode(tapCount: Int) -> Data; static func makeSockAddr(path: String) -> sockaddr_un }` and `public final class LineBuffer { func append(_ data: Data) -> [String] }`. Task 8's `SocketServer` uses `SocketIPC.encode`/`socketPath`/`makeSockAddr`; Task 10's `SocketClient` uses `LineBuffer`/`socketPath`/`makeSockAddr`. `makeSockAddr` is shared so the `sockaddr_un`-building boilerplate isn't duplicated between the two (preflight scan finding).

- [ ] **Step 1: Write the failing tests**

`Tests/KnockCoreTests/SocketIPCTests.swift`:
```swift
import XCTest
@testable import KnockCore

final class SocketIPCTests: XCTestCase {
    func testEncodeProducesDecimalPlusNewline() {
        let data = SocketIPC.encode(tapCount: 2)
        XCTAssertEqual(String(data: data, encoding: .utf8), "2\n")
    }

    func testLineBufferSplitsSingleChunk() {
        let buffer = LineBuffer()
        let lines = buffer.append(Data("1\n2\n".utf8))
        XCTAssertEqual(lines, ["1", "2"])
    }

    func testLineBufferHandlesSplitAcrossChunks() {
        let buffer = LineBuffer()
        let first = buffer.append(Data("1\n2".utf8))
        XCTAssertEqual(first, ["1"])
        let second = buffer.append(Data("\n3\n".utf8))
        XCTAssertEqual(second, ["2", "3"])
    }

    func testMakeSockAddrSetsFamilyAndPath() {
        var addr = SocketIPC.makeSockAddr(path: "/tmp/test.sock")
        XCTAssertEqual(addr.sun_family, sa_family_t(AF_UNIX))
        let path = withUnsafePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) { cstrPtr in
                String(cString: cstrPtr)
            }
        }
        XCTAssertEqual(path, "/tmp/test.sock")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SocketIPCTests`
Expected: FAIL — `SocketIPC`/`LineBuffer` not defined.

- [ ] **Step 3: Implement `SocketIPC.swift`**

`Sources/KnockCore/SocketIPC.swift`:
```swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum SocketIPC {
    public static let socketPath = "/tmp/knockd.sock"

    public static func encode(tapCount: Int) -> Data {
        Data("\(tapCount)\n".utf8)
    }

    /// Builds a sockaddr_un for the given path, for use with bind()/connect().
    /// Shared by knockd's SocketServer and KnockAgent's SocketClient so the
    /// sun_path-filling boilerplate exists in exactly one place.
    public static func makeSockAddr(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) { cstrPtr in
                path.withCString { pathPtr in
                    strncpy(cstrPtr, pathPtr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
                }
            }
        }
        return addr
    }
}

/// Buffers raw socket bytes and yields complete newline-terminated lines,
/// carrying partial lines over between calls to `append`.
public final class LineBuffer {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SocketIPCTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/KnockCore/SocketIPC.swift Tests/KnockCoreTests/SocketIPCTests.swift
git commit -m "Add SocketIPC line protocol (encode + LineBuffer)"
```

---

## Task 6: KnockCore — ActionExecuting protocol and ActionRunner

**Files:**
- Create: `Sources/KnockCore/ActionRunner.swift`
- Test: `Tests/KnockCoreTests/ActionRunnerTests.swift`

**Interfaces:**
- Consumes: `ActionConfig` (Task 4).
- Produces: `public protocol ActionExecuting { func mute() throws; func mediaPlayPause() throws; func runShellCommand(_ command: String) throws }` and `public final class ActionRunner { init(executor: ActionExecuting); func run(_ action: ActionConfig) throws }`. Task 9's `SystemActionExecutor` conforms to `ActionExecuting`; Task 11's `AgentModel` constructs `ActionRunner(executor: SystemActionExecutor())`.

- [ ] **Step 1: Write the failing tests**

`Tests/KnockCoreTests/ActionRunnerTests.swift`:
```swift
import XCTest
@testable import KnockCore

final class ActionRunnerTests: XCTestCase {
    final class FakeExecutor: ActionExecuting {
        var muteCalled = false
        var playPauseCalled = false
        var lastCommand: String?

        func mute() throws { muteCalled = true }
        func mediaPlayPause() throws { playPauseCalled = true }
        func runShellCommand(_ command: String) throws { lastCommand = command }
    }

    func testDispatchesMute() throws {
        let fake = FakeExecutor()
        try ActionRunner(executor: fake).run(ActionConfig(type: .mute))
        XCTAssertTrue(fake.muteCalled)
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ActionRunnerTests`
Expected: FAIL — `ActionExecuting`/`ActionRunner` not defined.

- [ ] **Step 3: Implement `ActionRunner.swift`**

`Sources/KnockCore/ActionRunner.swift`:
```swift
/// Performs the side-effecting half of an action. Implemented by
/// SystemActionExecutor (KnockAgent target) for real use, and by a fake
/// in tests, so ActionRunner's dispatch logic is testable without
/// touching CoreAudio/AppKit/Process.
public protocol ActionExecuting {
    func mute() throws
    func mediaPlayPause() throws
    func runShellCommand(_ command: String) throws
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
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ActionRunnerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/KnockCore/ActionRunner.swift Tests/KnockCoreTests/ActionRunnerTests.swift
git commit -m "Add ActionExecuting protocol and ActionRunner dispatch"
```

---

## Task 7: knockd — AccelerometerReader (IOKit HID wiring)

This task touches undocumented hardware and cannot be unit tested — verification is manual, on real hardware, with `sudo`.

**Files:**
- Create: `Sources/knockd/AccelerometerReader.swift`

**Interfaces:**
- Consumes: `AccelReportParser` (Task 3), `AccelSample` (Task 2).
- Produces: `public protocol AccelerometerReaderDelegate: AnyObject { func accelerometerReader(_ reader: AccelerometerReader, didReceive sample: AccelSample) }` and `public final class AccelerometerReader { var delegate: AccelerometerReaderDelegate?; func start() throws }`. Task 8's `main.swift` sets `delegate` and calls `start()`.

- [ ] **Step 1: Implement `AccelerometerReader.swift`**

`Sources/knockd/AccelerometerReader.swift`:
```swift
import Foundation
import IOKit.hid
import KnockCore

public protocol AccelerometerReaderDelegate: AnyObject {
    func accelerometerReader(_ reader: AccelerometerReader, didReceive sample: AccelSample)
}

/// Opens the internal accelerometer via IOKit HID. This is an undocumented
/// device (see the design doc's Background section) — matching is on
/// vendor usage page 0xFF00, usage 3, which is where community
/// reverse-engineering found it under AppleSPUHIDDevice. Requires root.
public final class AccelerometerReader {
    public enum AccelerometerError: Error {
        case openFailed(IOReturn)
    }

    public weak var delegate: AccelerometerReaderDelegate?

    private var manager: IOHIDManager?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private let reportBufferSize = 64

    public init() {}

    public func start() throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0xFF00,
            kIOHIDDeviceUsageKey as String: 3,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let matchingCallback: IOHIDDeviceCallback = { context, _, _, device in
            guard let context else { return }
            let reader = Unmanaged<AccelerometerReader>.fromOpaque(context).takeUnretainedValue()
            reader.attachReportCallback(device: device)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            matchingCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw AccelerometerError.openFailed(openResult)
        }
        self.manager = manager
    }

    private func attachReportCallback(device: IOHIDDevice) {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        reportBuffer = buffer

        let reportCallback: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
            guard let context, let report else { return }
            let reader = Unmanaged<AccelerometerReader>.fromOpaque(context).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
            guard let parsed = AccelReportParser.parse(bytes) else { return }
            let sample = AccelSample(
                timestamp: CFAbsoluteTimeGetCurrent(),
                x: parsed.x, y: parsed.y, z: parsed.z
            )
            reader.delegate?.accelerometerReader(reader, didReceive: sample)
        }

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            reportBufferSize,
            reportCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
```

- [ ] **Step 2: Manual verification on real hardware**

This is wired into `main.swift` in Task 8. After Task 8 is complete, run:

```bash
sudo swift run knockd
```

Then physically tap the chassis. Expected: console prints accelerometer-derived tap events.

If `IOHIDManagerOpen` fails or no device matches, run `ioreg -c AppleSPUHIDDevice -r -l` to inspect the actual usage page/usage/child structure on this machine and adjust the matching dictionary in `start()` — this is an undocumented interface and the exact values may differ slightly across firmware/macOS versions (see design doc's Risks section).

- [ ] **Step 3: Commit**

```bash
git add Sources/knockd/AccelerometerReader.swift
git commit -m "Add AccelerometerReader: IOKit HID wiring for internal accelerometer"
```

---

## Task 8: knockd — SocketServer and main.swift wiring

**Files:**
- Create: `Sources/knockd/SocketServer.swift`
- Modify: `Sources/knockd/main.swift` (replace Task 1's placeholder)

**Interfaces:**
- Consumes: `SocketIPC` (Task 5), `TapDetector`/`AccelSample` (Task 2), `AccelerometerReader`/`AccelerometerReaderDelegate` (Task 7), `ConfigStore`/`KnockConfig` (Task 4).
- Produces: `public final class SocketServer { init(path: String); func start() throws; func broadcast(tapCount: Int); func stop() }`. This is knockd-internal; no later task depends on it directly (KnockAgent only depends on the socket wire protocol via `SocketClient`, Task 10).

- [ ] **Step 1: Implement `SocketServer.swift`**

`Sources/knockd/SocketServer.swift`:
```swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import KnockCore

/// A Unix domain socket server that accepts any number of clients and
/// broadcasts tap-count events to all of them. Uses raw BSD sockets
/// (rather than Network.framework) for a small, easily-verified
/// implementation with no dependency surprises.
public final class SocketServer {
    public enum SocketError: Error {
        case systemError(Int32)
    }

    private let path: String
    private var listenFD: Int32 = -1
    private var clientFDs: [Int32] = []
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "knockd.socket")

    public init(path: String) {
        self.path = path
    }

    public func start() throws {
        unlink(path) // remove a stale socket file from a previous run

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw SocketError.systemError(errno) }

        var addr = SocketIPC.makeSockAddr(path: path)
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenFD, sockaddrPtr, addrSize)
            }
        }
        guard bindResult == 0 else { throw SocketError.systemError(errno) }

        chmod(path, 0o666) // the unprivileged KnockAgent process must be able to connect

        guard listen(listenFD, 4) == 0 else { throw SocketError.systemError(errno) }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.resume()
        acceptSource = source
    }

    /// Runs on `queue` (via acceptSource's event handler) — do not wrap
    /// the body in `queue.sync`, that would deadlock.
    private func acceptClient() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        clientFDs.append(clientFD)
    }

    public func broadcast(tapCount: Int) {
        let data = SocketIPC.encode(tapCount: tapCount)
        queue.async {
            self.clientFDs = self.clientFDs.filter { fd in
                let bytesWritten = data.withUnsafeBytes { rawBuffer -> Int in
                    write(fd, rawBuffer.baseAddress, rawBuffer.count)
                }
                if bytesWritten < 0 {
                    close(fd)
                    return false
                }
                return true
            }
        }
    }

    public func stop() {
        acceptSource?.cancel()
        for fd in clientFDs { close(fd) }
        clientFDs.removeAll()
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }
}
```

- [ ] **Step 2: Wire everything together in `main.swift`, including a `--simulate` mode**

The `--simulate` mode reads tap counts from stdin instead of the accelerometer, so the socket + KnockAgent can be tested end-to-end without root or physical hardware — save that for Task 12's verification.

`Sources/knockd/main.swift`:
```swift
import Foundation
import KnockCore

let simulate = CommandLine.arguments.contains("--simulate")

let config = (try? ConfigStore.load(from: ConfigStore.defaultPath)) ?? .default
let detector = TapDetector(sensitivity: config.sensitivity, windowSeconds: TimeInterval(config.windowMs) / 1000.0)
let server = SocketServer(path: SocketIPC.socketPath)

try server.start()
print("knockd listening on \(SocketIPC.socketPath)")

if simulate {
    print("Simulate mode: type a number + Enter to fake a tap-count event (no hardware/root needed).")
    while let line = readLine() {
        guard let count = Int(line) else { continue }
        server.broadcast(tapCount: count)
        print("Sent simulated \(count)-tap event")
    }
} else {
    final class ReaderDelegate: AccelerometerReaderDelegate {
        func accelerometerReader(_ reader: AccelerometerReader, didReceive sample: AccelSample) {
            if let count = detector.ingest(sample) {
                print("Detected \(count)-tap pattern")
                server.broadcast(tapCount: count)
            }
        }
    }

    let delegate = ReaderDelegate()
    let reader = AccelerometerReader()
    reader.delegate = delegate
    try reader.start()
    print("Reading accelerometer (requires root). Tap the chassis to test.")
    RunLoop.current.run()
}
```

- [ ] **Step 3: Verify it builds and simulate mode works**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run knockd --simulate`, then type `2` and press Enter.
Expected: prints `knockd listening on /tmp/knockd.sock` then `Sent simulated 2-tap event`.

In a second terminal, verify the socket actually carries the byte: `nc -U /tmp/knockd.sock` (run this *before* sending from the first terminal), then trigger a simulated tap in the first terminal.
Expected: the `nc` terminal prints `2`.

- [ ] **Step 4: Commit**

```bash
git add Sources/knockd/SocketServer.swift Sources/knockd/main.swift
git commit -m "Wire knockd: accelerometer/simulate -> TapDetector -> SocketServer"
```

---

## Task 9: KnockAgent — SystemActionExecutor

**Files:**
- Create: `Sources/KnockAgent/SystemActionExecutor.swift`

**Interfaces:**
- Consumes: `ActionExecuting` (Task 6).
- Produces: `final class SystemActionExecutor: ActionExecuting`. Task 11's `AgentModel` constructs `ActionRunner(executor: SystemActionExecutor())`.

- [ ] **Step 1: Implement `SystemActionExecutor.swift`**

`Sources/KnockAgent/SystemActionExecutor.swift`:
```swift
import Foundation
import AppKit
import CoreAudio
import KnockCore

/// The real, side-effecting implementation of ActionExecuting. Runs in
/// KnockAgent (the unprivileged, logged-in-user process) because these
/// actions need the user's audio/WindowServer session, which a root
/// process (knockd) cannot cleanly reach.
final class SystemActionExecutor: ActionExecuting {
    enum ExecutorError: Error {
        case audioPropertyFailed(OSStatus)
    }

    func mute() throws {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let getDeviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceIDSize, &deviceID
        )
        guard getDeviceStatus == noErr else { throw ExecutorError.audioPropertyFailed(getDeviceStatus) }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isMuted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let getMuteStatus = AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &muteSize, &isMuted)
        guard getMuteStatus == noErr else { throw ExecutorError.audioPropertyFailed(getMuteStatus) }

        var newMute: UInt32 = isMuted == 0 ? 1 : 0
        let setStatus = AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, muteSize, &newMute)
        guard setStatus == noErr else { throw ExecutorError.audioPropertyFailed(setStatus) }
    }

    func mediaPlayPause() throws {
        let NX_KEYTYPE_PLAY: Int32 = 16
        postMediaKey(NX_KEYTYPE_PLAY)
    }

    func runShellCommand(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        try process.run()
    }

    private func postMediaKey(_ key: Int32) {
        func post(down: Bool) {
            let data1 = Int((Int(key) << 16) | (down ? 0xa00 : 0xb00) << 8)
            let flags: NSEvent.ModifierFlags = down ? NSEvent.ModifierFlags(rawValue: 0xa00) : NSEvent.ModifierFlags(rawValue: 0xb00)
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
}
```

- [ ] **Step 2: Manual verification**

This is exercised end-to-end in Task 12. As a quick standalone check once Task 11 exists, trigger each action from the running KnockAgent (e.g. via the settings UI's "Add mapping" + a manual socket write) and confirm: system mute toggles, media play/pause affects the current player, and a `shellCommand` like `open -a Notes` launches the app.

- [ ] **Step 3: Commit**

```bash
git add Sources/KnockAgent/SystemActionExecutor.swift
git commit -m "Add SystemActionExecutor: mute, media play/pause, shell command"
```

---

## Task 10: KnockAgent — SocketClient

**Files:**
- Create: `Sources/KnockAgent/SocketClient.swift`

**Interfaces:**
- Consumes: `SocketIPC`/`LineBuffer` (Task 5).
- Produces: `final class SocketClient { init(path: String); var onTapCount: ((Int) -> Void)?; var onConnectionChange: ((Bool) -> Void)?; func start(); func stop() }`. Task 11's `AgentModel` constructs this and sets both callbacks.

- [ ] **Step 1: Implement `SocketClient.swift`**

`Sources/KnockAgent/SocketClient.swift`:
```swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import KnockCore

/// Connects to knockd's Unix domain socket and reconnects every 3 seconds
/// if knockd isn't running yet (or restarts). This is what lets KnockAgent
/// show a "knockd connected?" status regardless of start order between
/// the two processes.
final class SocketClient {
    private let path: String
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var reconnectTimer: DispatchSourceTimer?
    private let lineBuffer = LineBuffer()
    private let queue = DispatchQueue(label: "knockagent.socket")

    var onTapCount: ((Int) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() {
        queue.async { [weak self] in
            self?.attemptConnect()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, self.fd < 0 else { return }
            self.attemptConnect()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func attemptConnect() {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }

        var addr = SocketIPC.makeSockAddr(path: path)
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(socketFD, sockaddrPtr, addrSize)
            }
        }
        guard connectResult == 0 else {
            close(socketFD)
            return
        }

        fd = socketFD
        onConnectionChange?(true)

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        source.setCancelHandler { [weak self] in
            close(socketFD)
            self?.fd = -1
            self?.onConnectionChange?(false)
        }
        source.resume()
        readSource = source
    }

    private func handleReadable() {
        var buffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else {
            readSource?.cancel()
            return
        }
        let data = Data(buffer[0..<bytesRead])
        for line in lineBuffer.append(data) {
            if let count = Int(line) {
                onTapCount?(count)
            }
        }
    }

    func stop() {
        reconnectTimer?.cancel()
        readSource?.cancel()
    }
}
```

- [ ] **Step 2: Manual verification**

Deferred to Task 12, which needs `AgentModel` (Task 11) to observe `onTapCount` end-to-end against `knockd --simulate`.

- [ ] **Step 3: Commit**

```bash
git add Sources/KnockAgent/SocketClient.swift
git commit -m "Add SocketClient: connects to knockd with automatic reconnect"
```

---

## Task 11: KnockAgent — AgentModel, SettingsView, menu bar app

**Files:**
- Create: `Sources/KnockAgent/AgentModel.swift`
- Create: `Sources/KnockAgent/SettingsView.swift`
- Modify: `Sources/KnockAgent/main.swift` → rename to `Sources/KnockAgent/KnockAgentApp.swift` (SwiftUI apps need an `App`-conforming type; `@main` replaces the old placeholder `main.swift` entry point)

**Interfaces:**
- Consumes: `KnockConfig`/`ConfigStore`/`ConfigWatcher` (Task 4), `ActionRunner` (Task 6), `SystemActionExecutor` (Task 9), `SocketClient` (Task 10), `SocketIPC` (Task 5).
- Produces: `final class AgentModel: ObservableObject { @Published var config: KnockConfig; @Published var isConnected: Bool; func save(_ newConfig: KnockConfig) }`. Nothing later depends on this — it's the top of the dependency graph.

- [ ] **Step 1: Remove the placeholder entry point**

```bash
git rm Sources/KnockAgent/main.swift
```

- [ ] **Step 2: Implement `AgentModel.swift`**

`Sources/KnockAgent/AgentModel.swift`:
```swift
import Foundation
import KnockCore

final class AgentModel: ObservableObject {
    @Published var config: KnockConfig
    @Published var isConnected: Bool = false

    private let configURL = ConfigStore.defaultPath
    private var watcher: ConfigWatcher?
    private let socketClient = SocketClient(path: SocketIPC.socketPath)
    private let actionRunner = ActionRunner(executor: SystemActionExecutor())

    init() {
        if let loaded = try? ConfigStore.load(from: configURL) {
            config = loaded
        } else {
            config = .default
            try? ConfigStore.save(.default, to: configURL)
        }

        socketClient.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async { self?.isConnected = connected }
        }
        socketClient.onTapCount = { [weak self] count in
            guard let self, let action = self.config.mappings["\(count)"] else { return }
            try? self.actionRunner.run(action)
        }
        socketClient.start()

        let watcher = ConfigWatcher(url: configURL) { [weak self] newConfig in
            DispatchQueue.main.async { self?.config = newConfig }
        }
        watcher.start()
        self.watcher = watcher
    }

    func save(_ newConfig: KnockConfig) {
        config = newConfig
        try? ConfigStore.save(newConfig, to: configURL)
    }
}
```

- [ ] **Step 3: Implement `SettingsView.swift`**

`Sources/KnockAgent/SettingsView.swift`:
```swift
import SwiftUI
import AppKit
import KnockCore

struct SettingsView: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isConnected ? "knockd: connected" : "knockd: not running (start with sudo)")
                .foregroundStyle(model.isConnected ? .green : .red)

            Divider()

            ForEach(model.config.mappings.sorted(by: { $0.key < $1.key }), id: \.key) { tapCount, action in
                HStack {
                    Text("\(tapCount) tap(s)")
                    Spacer()
                    Text(action.type.rawValue)
                    Button("Remove") {
                        var updated = model.config
                        updated.mappings.removeValue(forKey: tapCount)
                        model.save(updated)
                    }
                }
            }

            Divider()
            AddMappingForm(model: model)

            Divider()
            VStack(alignment: .leading) {
                Text("Sensitivity: \(model.config.sensitivity, specifier: "%.2f")")
                Slider(
                    value: Binding(
                        get: { model.config.sensitivity },
                        set: { newValue in
                            var updated = model.config
                            updated.sensitivity = newValue
                            model.save(updated)
                        }
                    ),
                    in: 0.1...1.0
                )
            }

            Divider()
            Button("Quit Knock") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 320)
    }
}

private struct AddMappingForm: View {
    @ObservedObject var model: AgentModel
    @State private var tapCount = "1"
    @State private var actionType: ActionConfig.Kind = .mute
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add mapping").bold()
            HStack {
                TextField("Tap count", text: $tapCount).frame(width: 60)
                Picker("", selection: $actionType) {
                    Text("Mute").tag(ActionConfig.Kind.mute)
                    Text("Play/Pause").tag(ActionConfig.Kind.mediaPlayPause)
                    Text("Shell command").tag(ActionConfig.Kind.shellCommand)
                }
                .frame(width: 140)
            }
            if actionType == .shellCommand {
                TextField("Command", text: $command)
            }
            Button("Add") {
                var updated = model.config
                updated.mappings[tapCount] = ActionConfig(
                    type: actionType,
                    command: actionType == .shellCommand ? command : nil
                )
                model.save(updated)
            }
        }
    }
}
```

- [ ] **Step 4: Implement `KnockAgentApp.swift`**

`Sources/KnockAgent/KnockAgentApp.swift`:
```swift
import SwiftUI

@main
struct KnockAgentApp: App {
    @StateObject private var model = AgentModel()

    var body: some Scene {
        MenuBarExtra(model.isConnected ? "Knock ●" : "Knock ○", systemImage: "hand.tap") {
            SettingsView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 5: Verify it builds and launches**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run KnockAgent`
Expected: a menu bar icon appears; clicking it shows the settings window with the default mappings (1 tap → Play/Pause, 2 taps → Mute) and a red "knockd: not running" status (since knockd isn't running yet).

- [ ] **Step 6: Commit**

```bash
git add Sources/KnockAgent/AgentModel.swift Sources/KnockAgent/SettingsView.swift Sources/KnockAgent/KnockAgentApp.swift
git commit -m "Add KnockAgent menu bar UI: settings, mappings, connection status"
```

---

## Task 12: End-to-end verification and README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: the whole system.
- Produces: nothing new — this task is verification plus documentation for future-you.

- [ ] **Step 1: Verify simulate mode end-to-end**

Terminal 1: `swift run knockd --simulate`
Terminal 2: `swift run KnockAgent`

In the KnockAgent settings window, confirm the default mapping for `2` is `mute`. In Terminal 1, type `2` and press Enter.
Expected: system audio mutes (menu bar volume icon shows muted), and Terminal 1 prints `Sent simulated 2-tap event`.

Type `1` and press Enter.
Expected: whatever's currently playing (e.g. Music/Spotify) pauses or resumes.

- [ ] **Step 2: Verify real hardware end-to-end**

Quit the simulate-mode `knockd` (Ctrl-C). Run instead:

```bash
sudo swift run knockd
```

Physically tap the chassis twice in quick succession.
Expected: Terminal prints `Detected 2-tap pattern`, and (per the default mapping) audio mutes.

If taps aren't detected, or single taps are detected as multiple, adjust `sensitivity`/`windowMs` via the KnockAgent settings UI (the slider) — `knockd` picks up the change live via `ConfigWatcher`, no restart needed. If false positives occur from normal typing/handling, raise `sensitivity`.

- [ ] **Step 3: Verify a shell command mapping**

In the KnockAgent settings UI, add a mapping: tap count `3`, action `shellCommand`, command `open -a Notes`. Trigger it (simulate `3` or physically triple-tap).
Expected: Notes.app launches.

- [ ] **Step 4: Write `README.md`**

`README.md`:
```markdown
# Knock (personal build)

A free, personal alternative to the Knock app: detect tap patterns on
the MacBook chassis via the internal accelerometer and trigger mute,
media play/pause, or a shell command.

See `docs/superpowers/specs/2026-09-08-knock-detector-design.md` for
the full design and background on how the (undocumented) accelerometer
access works.

## Build

```bash
swift build
```

## Run

Two processes, in two terminals:

```bash
# Terminal 1: the sensor daemon. Requires root to read the accelerometer.
sudo swift run knockd

# Terminal 2: the menu bar app (settings UI + action execution).
swift run KnockAgent
```

`knockd` also has a `--simulate` mode for testing without root/hardware
— type a number and press Enter to fake a tap-count event:

```bash
swift run knockd --simulate
```

## Configuring tap → action mappings

Use the KnockAgent menu bar icon's settings window, or edit
`~/Library/Application Support/Knock/config.json` directly — both
`knockd` (sensitivity/window) and `KnockAgent` (mappings) pick up
changes to this file live, no restart needed.

## Known limitations

- Tested on M3. The accelerometer interface is undocumented by Apple
  and may need adjustment on other chip generations (see the design
  doc).
- `knockd` must be started manually with `sudo` each session — no
  auto-start is set up (see design doc's Future Work for how to add a
  LaunchDaemon later without changing any code).
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Add README with build/run instructions"
```
