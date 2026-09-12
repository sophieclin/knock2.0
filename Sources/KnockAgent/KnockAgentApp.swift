import SwiftUI
import AppKit

/// KnockAgent is run as a bare SwiftPM executable (no .app bundle / Info.plist),
/// so LaunchServices treats it as background-only, which forbids menu bar
/// items — the MenuBarExtra silently never appears. Declaring ourselves an
/// accessory app (menu bar item, no Dock icon) fixes that.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@main
struct KnockAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AgentModel()

    var body: some Scene {
        MenuBarExtra(model.isConnected ? "Knock ●" : "Knock ○", systemImage: "hand.tap") {
            SettingsView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
