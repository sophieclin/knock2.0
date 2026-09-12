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
