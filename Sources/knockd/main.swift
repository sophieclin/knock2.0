import Foundation
import KnockCore

// Belt-and-braces alongside SO_NOSIGPIPE on each client fd in SocketServer:
// writing to a socket whose peer has closed its read side raises SIGPIPE,
// which by default terminates the process. Clients (KnockAgent) are
// expected to disconnect and reconnect routinely, so the daemon must not
// die when that happens.
signal(SIGPIPE, SIG_IGN)

let simulate = CommandLine.arguments.contains("--simulate")
// --debug: print sample rate and deviation stats so `sensitivity` can be
// tuned against what real taps actually look like on this machine.
let debug = CommandLine.arguments.contains("--debug")

// --config PATH: explicit config file. Needed when launched by launchd as a
// LaunchDaemon, where there is no SUDO_USER to locate the user's home.
let configURL: URL = {
    let args = CommandLine.arguments
    if let flag = args.firstIndex(of: "--config"), flag + 1 < args.count {
        return URL(fileURLWithPath: args[flag + 1])
    }
    return ConfigStore.defaultPath
}()

let config = (try? ConfigStore.load(from: configURL)) ?? .default
let detector = TapDetector(sensitivity: config.sensitivity, windowSeconds: TimeInterval(config.windowMs) / 1000.0)
let server = SocketServer(path: SocketIPC.socketPath)

try server.start()
print("knockd listening on \(SocketIPC.socketPath)")

// Remove the socket file on Ctrl-C / kill. When run under sudo it is owned
// by root, and a leftover would block any later non-root `--simulate` run
// (unlink in sticky /tmp needs the owner). Handled on a background queue
// because simulate mode blocks the main thread in readLine().
let shutdownSignals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler {
        server.stop()
        exit(0)
    }
    source.resume()
    return source
}

if simulate {
    print("Simulate mode: type a number + Enter to fake a tap-count event (no hardware/root needed).")
    while let line = readLine() {
        guard let count = Int(line) else { continue }
        server.broadcast(tapCount: count)
        print("Sent simulated \(count)-tap event")
    }
} else {
    final class ReaderDelegate: AccelerometerReaderDelegate {
        private var windowStart: TimeInterval = 0
        private var samplesInWindow = 0
        private var maxDeviationInWindow = 0.0

        func accelerometerReader(_ reader: AccelerometerReader, didReceive sample: AccelSample) {
            if let count = detector.ingest(sample) {
                print("Detected \(count)-tap pattern")
                server.broadcast(tapCount: count)
            }
            if debug { logDebugStats(sample) }
        }

        /// Once per second: sample rate and the largest deviation seen, so the
        /// noise floor (sitting still / typing) and tap peaks can be compared
        /// against `sensitivity`.
        private func logDebugStats(_ sample: AccelSample) {
            if windowStart == 0 { windowStart = sample.timestamp }
            samplesInWindow += 1
            maxDeviationInWindow = max(maxDeviationInWindow, detector.lastDeviation)
            if sample.timestamp - windowStart >= 1 {
                let flag = maxDeviationInWindow > detector.sensitivity ? "  <-- over threshold" : ""
                print(String(format: "[debug] %3d Hz  peak deviation %.3f g  (threshold %.2f)%@",
                             samplesInWindow, maxDeviationInWindow, detector.sensitivity, flag))
                windowStart = sample.timestamp
                samplesInWindow = 0
                maxDeviationInWindow = 0
            }
        }
    }

    let delegate = ReaderDelegate()
    let reader = AccelerometerReader()
    reader.delegate = delegate
    try reader.start()

    // Pick up sensitivity/window changes made in KnockAgent's UI without a
    // restart. Both the watcher and the HID callbacks run on the main run
    // loop, so mutating the detector here is safe.
    let watcher = ConfigWatcher(url: configURL) { newConfig in
        detector.sensitivity = newConfig.sensitivity
        detector.windowSeconds = TimeInterval(newConfig.windowMs) / 1000.0
        print("Config reloaded: sensitivity=\(newConfig.sensitivity) windowMs=\(newConfig.windowMs)")
    }
    watcher.start()

    print("Reading accelerometer (requires root). Tap the chassis to test.")
    RunLoop.current.run()
}
