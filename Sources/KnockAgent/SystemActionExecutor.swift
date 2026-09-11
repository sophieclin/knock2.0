import Foundation
import AppKit
import CoreAudio
import KnockCore

/// The real, side-effecting implementation of ActionExecuting. Runs in
/// KnockAgent (the unprivileged, logged-in-user process) because these
/// actions need the user's audio/WindowServer session, which a root
/// process (knockd) cannot cleanly reach.
final class SystemActionExecutor: ActionExecuting {
    enum ExecutorError: Error {
        case audioPropertyFailed(OSStatus)
    }

    func mute() throws {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let getDeviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceIDSize, &deviceID
        )
        guard getDeviceStatus == noErr else { throw ExecutorError.audioPropertyFailed(getDeviceStatus) }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isMuted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let getMuteStatus = AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &muteSize, &isMuted)
        guard getMuteStatus == noErr else { throw ExecutorError.audioPropertyFailed(getMuteStatus) }

        var newMute: UInt32 = isMuted == 0 ? 1 : 0
        let setStatus = AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, muteSize, &newMute)
        guard setStatus == noErr else { throw ExecutorError.audioPropertyFailed(setStatus) }
    }

    func mediaPlayPause() throws {
        let NX_KEYTYPE_PLAY: Int32 = 16
        postMediaKey(NX_KEYTYPE_PLAY)
    }

    func runShellCommand(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        try process.run()
    }

    private func postMediaKey(_ key: Int32) {
        func post(down: Bool) {
            let data1 = Int((Int(key) << 16) | (down ? 0xa00 : 0xb00) << 8)
            let flags: NSEvent.ModifierFlags = down ? NSEvent.ModifierFlags(rawValue: 0xa00) : NSEvent.ModifierFlags(rawValue: 0xb00)
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
}
