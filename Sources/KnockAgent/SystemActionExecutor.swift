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
        case noPreviousApp
        case accessibilityNotGranted
        case eventCreationFailed
    }

    /// Posting keyboard events to other apps needs the Accessibility
    /// permission (System Settings > Privacy & Security > Accessibility) for
    /// the process that launched us — the terminal, when run via `swift run`.
    /// Without it the events are silently dropped, so ask up front; the
    /// system shows its prompt only the first time.
    func pressKeys(_ combo: KeyCombo) throws {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
            throw ExecutorError.accessibilityNotGranted
        }

        var flags = CGEventFlags()
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: false) else {
            throw ExecutorError.eventCreationFailed
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // Activation history for `switchToPreviousApp`. Seeded with whatever is
    // frontmost at launch so the first switch after startup has a target.
    private var recentApps = RecentAppTracker(ownPID: ProcessInfo.processInfo.processIdentifier)
    private var activationObserver: NSObjectProtocol?

    init() {
        if let front = NSWorkspace.shared.frontmostApplication {
            recentApps.noteActivated(pid: front.processIdentifier)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recentApps.noteActivated(pid: app.processIdentifier)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Tap events arrive on the socket queue; `recentApps` is only touched on
    /// main (where the observer runs), so hop there.
    func switchToPreviousApp() throws {
        let work = { () throws -> Void in
            guard let pid = self.recentApps.previousPID, let app = NSRunningApplication(processIdentifier: pid) else {
                throw ExecutorError.noPreviousApp
            }
            app.activate(options: .activateIgnoringOtherApps)
        }
        if Thread.isMainThread {
            try work()
        } else {
            try DispatchQueue.main.sync(execute: work)
        }
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
            let data1 = Int((Int(key) << 16) | (down ? 0xa00 : 0xb00))
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
