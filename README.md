# Knock (personal build)

A free, personal alternative to the Knock app: detect tap patterns on
the MacBook chassis via the internal accelerometer and trigger mute,
media play/pause, or a shell command.

See `docs/superpowers/specs/2026-09-08-knock-detector-design.md` for
the full design and background on how the (undocumented) accelerometer
access works.

## Build

```bash
swift build
```

## Run

Two processes, in two terminals:

```bash
# Terminal 1: the sensor daemon. Requires root to read the accelerometer.
sudo swift run knockd

# Terminal 2: the menu bar app (settings UI + action execution).
swift run KnockAgent
```

`knockd` also has a `--simulate` mode for testing without root/hardware
— type a number and press Enter to fake a tap-count event:

```bash
swift run knockd --simulate
```

## Run automatically at boot/login

```bash
scripts/install.sh      # asks for your password (installs a root LaunchDaemon)
```

This builds release binaries into `/usr/local/libexec/knock/`, installs
`knockd` as a LaunchDaemon (starts at boot, as root) and `KnockAgent` as
a LaunchAgent (starts at login), and starts both now. Re-run it after
pulling code changes. Logs go to `/var/log/knockd.log` and
`~/Library/Logs/KnockAgent.log`. `scripts/uninstall.sh` removes it all
(keeps your config).

If you use Keystroke actions, grant Accessibility permission to
`/usr/local/libexec/knock/KnockAgent` when macOS prompts — this is a
separate grant from the one your terminal has, and needs redoing after a
reinstall because the binary changes.

## Configuring tap → action mappings

Use the KnockAgent menu bar icon's settings window, or edit
`~/Library/Application Support/KnockDetector/config.json` directly — both
`knockd` (sensitivity/window) and `KnockAgent` (mappings) pick up
changes to this file live, no restart needed.

(The directory is `KnockDetector`, not `Knock`, so this build never
touches the commercial Knock app's config at `.../Knock/config.json`.)

## Known limitations

- Tested on M3. The accelerometer interface is undocumented by Apple
  and may need adjustment on other chip generations (see the design
  doc).
- `knockd` must be started manually with `sudo` each session — no
  auto-start is set up (see design doc's Future Work for how to add a
  LaunchDaemon later without changing any code).
