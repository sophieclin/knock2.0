import SwiftUI
import AppKit
import KnockCore

struct SettingsView: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isConnected ? "knockd: connected" : "knockd: not running (start with sudo)")
                .foregroundStyle(model.isConnected ? .green : .red)

            Divider()

            ForEach(model.config.mappings.sorted(by: { $0.key < $1.key }), id: \.key) { tapCount, action in
                HStack {
                    Text("\(tapCount) tap(s)")
                    Spacer()
                    Text(action.type.rawValue)
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
                    in: 0.1...1.0
                )
            }

            Divider()
            Button("Quit Knock") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 320)
    }
}

private struct AddMappingForm: View {
    @ObservedObject var model: AgentModel
    @State private var tapCount = "1"
    @State private var actionType: ActionConfig.Kind = .mute
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add mapping").bold()
            HStack {
                TextField("Tap count", text: $tapCount).frame(width: 60)
                Picker("", selection: $actionType) {
                    Text("Mute").tag(ActionConfig.Kind.mute)
                    Text("Play/Pause").tag(ActionConfig.Kind.mediaPlayPause)
                    Text("Shell command").tag(ActionConfig.Kind.shellCommand)
                }
                .frame(width: 140)
            }
            if actionType == .shellCommand {
                TextField("Command", text: $command)
            }
            Button("Add") {
                var updated = model.config
                updated.mappings[tapCount] = ActionConfig(
                    type: actionType,
                    command: actionType == .shellCommand ? command : nil
                )
                model.save(updated)
            }
        }
    }
}
