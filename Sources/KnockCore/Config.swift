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
    /// Deliberately not `.../Knock/config.json`: that directory is already
    /// used by the commercial Knock app with an incompatible schema, and
    /// we must not overwrite it.
    public static var defaultPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("KnockDetector", isDirectory: true).appendingPathComponent("config.json")
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
