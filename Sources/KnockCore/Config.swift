import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ActionConfig: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        case mute
        case mediaPlayPause
        case shellCommand
        case previousApp
        case keystroke
        case openApp
    }

    public let type: Kind
    /// Shell command for `.shellCommand`.
    public let command: String?
    /// Shortcut spec for `.keystroke`, e.g. "cmd+shift+4" (see KeyCombo.parse).
    public let keys: String?
    /// Application name for `.openApp`, as shown in Finder, e.g. "Claude".
    public let app: String?

    public init(type: Kind, command: String? = nil, keys: String? = nil, app: String? = nil) {
        self.type = type
        self.command = command
        self.keys = keys
        self.app = app
    }
}

public struct KnockConfig: Codable, Equatable {
    public var sensitivity: Double
    public var windowMs: Int
    public var mappings: [String: ActionConfig]
    /// Master on/off switch: when false, KnockAgent ignores tap events.
    /// Persisted so a deliberate "off" survives restarts.
    public var enabled: Bool

    public init(sensitivity: Double, windowMs: Int, mappings: [String: ActionConfig], enabled: Bool = true) {
        self.sensitivity = sensitivity
        self.windowMs = windowMs
        self.mappings = mappings
        self.enabled = enabled
    }

    // Custom decoding so config files written before `enabled` existed
    // still load (as enabled).
    private enum CodingKeys: String, CodingKey { case sensitivity, windowMs, mappings, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sensitivity = try c.decode(Double.self, forKey: .sensitivity)
        windowMs = try c.decode(Int.self, forKey: .windowMs)
        mappings = try c.decode([String: ActionConfig].self, forKey: .mappings)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public static let `default` = KnockConfig(
        sensitivity: 0.08, // see TapDetector.init for where this number comes from
        windowMs: 400,
        mappings: [
            "1": ActionConfig(type: .mediaPlayPause),
            "2": ActionConfig(type: .mute),
        ]
    )
}

public enum ConfigStore {
    /// Deliberately not `.../Knock/config.json`: that directory is already
    /// used by the commercial Knock app with an incompatible schema, and
    /// we must not overwrite it.
    public static var defaultPath: URL {
        defaultPath(environment: ProcessInfo.processInfo.environment)
    }

    /// knockd runs under `sudo`, where HOME is /var/root. Resolve against
    /// the invoking user's home (via SUDO_USER) so both processes share the
    /// one config file that KnockAgent writes.
    static func defaultPath(environment: [String: String]) -> URL {
        var home = FileManager.default.homeDirectoryForCurrentUser
        if let sudoUser = environment["SUDO_USER"], let entry = getpwnam(sudoUser) {
            home = URL(fileURLWithPath: String(cString: entry.pointee.pw_dir), isDirectory: true)
        }
        return home
            .appendingPathComponent("Library/Application Support/KnockDetector", isDirectory: true)
            .appendingPathComponent("config.json")
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
            guard let self, let event = self.source?.data else { return }
            // ConfigStore.save is atomic (write temp + rename), which replaces
            // the inode we're watching. Re-open the path so later saves are
            // still seen; the new file is read below as part of this event.
            if event.contains(.rename) || event.contains(.delete) {
                self.stop()
                self.start()
            }
            guard let config = try? ConfigStore.load(from: self.url) else { return }
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
