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

    // The defaults must separate real activity as measured on an M3 MacBook
    // at 800 Hz via `knockd --debug`: typing peaks at ~0.047 g, the lightest
    // deliberate tap at ~0.097 g, a firm tap at ~0.30 g.

    /// Feeds 1 s at rest, one spike of `peak` g, then 1 s at rest, at 800 Hz.
    private func runDefaultDetector(spikeTo peak: Double) -> Int? {
        let detector = TapDetector()
        var t = 0.0
        let dt = 1.0 / 800.0
        var result: Int? = nil
        for _ in 0..<800 { _ = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.0)); t += dt }
        _ = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.0 + peak)); t += dt
        for _ in 0..<800 { result = detector.ingest(AccelSample(timestamp: t, x: 0, y: 0, z: 1.0)) ?? result; t += dt }
        return result
    }

    func testDefaultSensitivityDetectsLightestMeasuredTap() {
        XCTAssertEqual(runDefaultDetector(spikeTo: 0.097), 1)
    }

    func testDefaultSensitivityIgnoresHardestMeasuredTyping() {
        XCTAssertNil(runDefaultDetector(spikeTo: 0.047))
    }
}
