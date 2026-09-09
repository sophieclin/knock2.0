# Knock Detector — Design

A personal, free alternative to the Knock app: detect taps on the MacBook
chassis via the built-in accelerometer and trigger configurable actions.
Single-user, personal use only — not for distribution.

## Goals

- Detect 1/2/3-tap patterns on the chassis using the internal accelerometer.
- Map each tap pattern to one of: mute/unmute, media play/pause, or an
  arbitrary shell command (covers "launch app" via `open -a ...`, run a
  script, take a screenshot, etc).
- Lightweight settings UI (menu bar app) to edit those mappings — no need
  for a fully polished app.
- Runs on Apple Silicon (target: M3), macOS current release.

## Non-goals

- No support for Intel Macs (the sensor doesn't exist there in the same
  form) or macOS distribution/signing/notarization for other users.
- No positional detection (e.g. "top-left corner" vs "top-right corner")
  — a single chassis accelerometer can't reliably distinguish tap
  location, only count and rough timing.
- No auto-start-at-boot in v1 (see Future Work).

## Background / feasibility

Apple does not document access to the internal accelerometer. Community
reverse-engineering (MIT-licensed [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer),
independently confirmed by [taigrr/apple-silicon-accelerometer](https://github.com/taigrr/apple-silicon-accelerometer)
and [taigrr/spank](https://github.com/taigrr/spank)) has established:

- The device appears in the IOKit registry under `AppleSPUHIDDevice`,
  on vendor usage page `0xFF00`. Usage `3` is the accelerometer, usage
  `9` is the gyroscope (unused here).
- Input reports are 22 bytes. X/Y/Z accelerometer values are
  little-endian `int32` at byte offsets 6, 10, 14 respectively, in
  units of 1/65536 g. Native report rate is ~800Hz.
- Opening the device requires **root**. This is a hard requirement,
  not a permissions prompt we can work around with Input Monitoring
  or similar TCC grants — third-party (non-root) processes cannot open
  this HID device at all.
- olvvier's project reports testing on M3 Pro specifically; taigrr's
  reports M1 Pro/M2/M3 (and non-support on Intel and M4 Max — chip
  differences may shift exact offsets/behavior in the future, since
  this is explicitly an undocumented/unstable interface that "may
  break on future macOS updates").

This is the single biggest technical risk in the project: it's built on
an undocumented interface with no Apple guarantee of stability. The
mitigation is to isolate all sensor-reading code behind one small
module (see Components below) so a future macOS/hardware change only
requires patching that module.

## Architecture

Two processes, split by required privilege:

```
┌─────────────────────────┐      unix domain socket      ┌──────────────────────────┐
│   knockd (root daemon)  │ ───────────────────────────► │  Knock menu bar app      │
│                          │   "tap_count: 2" messages    │  (runs as logged-in user)│
│  - opens HID device      │                              │                          │
│  - reads accel stream    │                              │  - settings UI           │
│  - runs tap detector     │                              │  - owns config.json      │
└─────────────────────────┘                              │  - executes actions      │
                                                            └──────────────────────────┘
```

Actions are executed by the unprivileged menu bar app, not the root
daemon, because:
- A root process cannot cleanly reach the logged-in user's WindowServer
  / audio session, which several actions need (mute, media keys).
- Keeping the root process to "read sensor, detect pattern, emit event"
  minimizes what runs with elevated privilege.

### Component: `knockd` (sensor daemon)

- Swift command-line tool, run manually via `sudo ./knockd` for v1.
- Opens the accelerometer via `IOHIDManager`, matching on usage page
  `0xFF00` / usage `3` under `AppleSPUHIDDevice`.
- Tap detection: high-pass filter the accel magnitude (subtract a
  rolling average to remove gravity/orientation bias), threshold-cross
  on the filtered signal counts as one "hit." Hits occurring within a
  configurable window (default 400ms) of the first hit in a burst are
  grouped; the group's hit count is the tap pattern (1/2/3+ taps).
  Threshold and window are tunable (see Config).
- On a completed pattern (burst ends: no new hit within the window),
  writes a single line (e.g. `2\n`) to a Unix domain socket at a fixed
  path (e.g. `/tmp/knockd.sock`) that the menu bar app listens on. If
  no client is connected, the write is dropped (no queueing needed for
  a personal single-session tool).
- Reads `sensitivity` (threshold) and `windowMs` from the same
  `config.json` the menu bar app writes, reloading on file change
  (`DispatchSource` file watcher) — no restart needed to tune.

### Component: Knock menu bar app

- SwiftUI menu bar (`MenuBarExtra`) app, runs as the normal login user.
- Settings window: a simple list of tap-count → action rows (add/edit/
  remove), plus sensitivity/window sliders that write into the shared
  `config.json`.
- Listens on the Unix domain socket for tap-count messages from
  `knockd`; on receipt, looks up the mapped action and runs it:
  - `mute`: toggle system output mute (CoreAudio `AudioObjectSetPropertyData`
    on the default output device).
  - `mediaPlayPause`: post the media-key `CGEvent` (`NX_KEYTYPE_PLAY`).
  - `shellCommand`: run the configured command via `Process` (covers
    `open -a <App>`, arbitrary scripts, screenshot commands, etc).
- Also owns `~/Library/Application Support/Knock/config.json` as the
  single source of truth for both mappings and detector tuning.

### Config format

```json
{
  "sensitivity": 0.35,
  "windowMs": 400,
  "mappings": {
    "1": { "type": "mediaPlayPause" },
    "2": { "type": "mute" },
    "3": { "type": "shellCommand", "command": "open -a \"Notes\"" }
  }
}
```

## Data flow (end to end)

1. User taps the chassis twice.
2. `knockd` sees two threshold-crossing hits within the 400ms window,
   closes the burst, writes `2\n` to the socket.
3. Menu bar app reads `2` from the socket, looks up `mappings["2"]` in
   its in-memory config, finds `{"type": "mute"}`, toggles mute.

## Risks & open questions

- **Undocumented interface stability**: covered above; isolated to the
  `knockd` HID-reading module.
- **False positives**: normal typing, closing the lid, or setting the
  laptop down could register as taps. The threshold/window are
  expected to need real-world tuning after the first build — this is
  expected iteration, not a design flaw.
- **Root daemon lifecycle**: for v1 (manual start), if `knockd` isn't
  running, taps just do nothing — no error surfaced to the user. Worth
  a small "daemon connected?" indicator in the menu bar icon so it's
  obvious when it's not running.

## Future work (explicitly out of scope for v1)

- Auto-start `knockd` at boot via a `LaunchDaemon` (root, installed
  once with a setup script) instead of manual `sudo` start. No changes
  needed to `knockd` itself or the socket protocol — purely a packaging
  change.
- Additional built-in action types (lock screen, screenshot,
  brightness) if needed later — the `shellCommand` type already covers
  these via CLI (e.g. `pmset displaysleepnow` for lock-adjacent
  behavior).
