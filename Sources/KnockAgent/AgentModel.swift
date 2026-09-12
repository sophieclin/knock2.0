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
            do {
                try self.actionRunner.run(action)
            } catch {
                fputs("\(count)-tap action \(action.type) failed: \(error)\n", stderr)
            }
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
