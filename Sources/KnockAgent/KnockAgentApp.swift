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
