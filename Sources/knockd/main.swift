import Foundation
import KnockCore

// Belt-and-braces alongside SO_NOSIGPIPE on each client fd in SocketServer:
// writing to a socket whose peer has closed its read side raises SIGPIPE,
// which by default terminates the process. Clients (KnockAgent) are
// expected to disconnect and reconnect routinely, so the daemon must not
// die when that happens.
signal(SIGPIPE, SIG_IGN)

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

    // Pick up sensitivity/window changes made in KnockAgent's UI without a
    // restart. Both the watcher and the HID callbacks run on the main run
    // loop, so mutating the detector here is safe.
    let watcher = ConfigWatcher(url: ConfigStore.defaultPath) { newConfig in
        detector.sensitivity = newConfig.sensitivity
        detector.windowSeconds = TimeInterval(newConfig.windowMs) / 1000.0
        print("Config reloaded: sensitivity=\(newConfig.sensitivity) windowMs=\(newConfig.windowMs)")
    }
    watcher.start()

    print("Reading accelerometer (requires root). Tap the chassis to test.")
    RunLoop.current.run()
}
