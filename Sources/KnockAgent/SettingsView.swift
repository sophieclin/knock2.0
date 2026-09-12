import SwiftUI
import AppKit
import KnockCore

struct SettingsView: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enabled", isOn: Binding(
                get: { model.config.enabled },
                set: { newValue in
                    var updated = model.config
                    updated.enabled = newValue
                    model.save(updated)
                }
            ))
            .toggleStyle(.switch)

            Text(model.isConnected ? "knockd: connected" : "knockd: not running (start with sudo)")
                .foregroundStyle(model.isConnected ? .green : .red)

            Divider()

            ForEach(model.config.mappings.sorted(by: { $0.key < $1.key }), id: \.key) { tapCount, action in
                HStack {
                    Text("\(tapCount) tap(s)")
                    Spacer()
                    Text(describe(action))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Remove") {
                        var updated = model.config
                        updated.mappings.removeValue(forKey: tapCount)
                        model.save(updated)
                    }
                }
            }

            Divider()
            AddMappingForm(model: model)

            Divider()
            VStack(alignment: .leading) {
                Text("Sensitivity: \(model.config.sensitivity, specifier: "%.2f")")
                Slider(
                    value: Binding(
                        get: { model.config.sensitivity },
                        set: { newValue in
                            var updated = model.config
                            updated.sensitivity = newValue
                            model.save(updated)
                        }
                    ),
                    // Typing measures ~0.05 g, taps 0.1–0.3 g; keep the useful
                    // range reachable rather than starting at 0.1.
                    in: 0.02...0.5
                )
            }

            Divider()
            Button("Quit Knock") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 320)
    }

    private func describe(_ action: ActionConfig) -> String {
        switch action.type {
        case .mute: return "Mute"
        case .mediaPlayPause: return "Play/Pause"
        case .previousApp: return "Previous app"
        case .shellCommand: return "Shell: \(action.command ?? "")"
        case .keystroke: return "Keys: \(action.keys ?? "")"
        }
    }
}

private struct AddMappingForm: View {
    @ObservedObject var model: AgentModel
    @State private var tapCount = "1"
    @State private var actionType: ActionConfig.Kind = .mute
    @State private var command = ""
    @State private var keys = ""

    private var keysAreValid: Bool { KeyCombo.parse(keys) != nil }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add mapping").bold()
            HStack {
                TextField("Tap count", text: $tapCount).frame(width: 60)
                Picker("", selection: $actionType) {
                    Text("Mute").tag(ActionConfig.Kind.mute)
                    Text("Play/Pause").tag(ActionConfig.Kind.mediaPlayPause)
                    Text("Shell command").tag(ActionConfig.Kind.shellCommand)
                    Text("Previous app").tag(ActionConfig.Kind.previousApp)
                    Text("Keystroke").tag(ActionConfig.Kind.keystroke)
                }
                .frame(width: 140)
            }
            if actionType == .shellCommand {
                TextField("Command", text: $command)
            }
            if actionType == .keystroke {
                TextField("e.g. cmd+shift+4 or cmd+c", text: $keys)
                if !keys.isEmpty && !keysAreValid {
                    Text("Unrecognized shortcut").font(.caption).foregroundStyle(.red)
                }
            }
            Button("Add") {
                var updated = model.config
                updated.mappings[tapCount] = ActionConfig(
                    type: actionType,
                    command: actionType == .shellCommand ? command : nil,
                    keys: actionType == .keystroke ? keys : nil
                )
                model.save(updated)
            }
            .disabled(actionType == .keystroke && !keysAreValid)
        }
    }
}
