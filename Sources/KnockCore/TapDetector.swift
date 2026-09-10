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
