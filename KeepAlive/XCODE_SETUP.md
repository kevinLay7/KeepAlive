# KeepAlive — Xcode project notes

Short reference for the project layout. Most users don't need this — `README.md` covers install. Read this only if you're editing the Xcode project or the helper build.

## Layout

```
KeepAlive/
    KeepAlive.xcodeproj/
    KeepAlive/                       # main menu-bar app target
        KeepAliveApp.swift
        MenuBarView.swift
        PowerManager.swift           # assertions + nudge scheduler + fallback
        KarabinerBridge.swift        # 1-byte UDP client → root helper
        SessionTimer.swift
        Schedule.swift
        ScheduleManager.swift
        ScheduleEditorView.swift
        Assets.xcassets
        KeepAlive.entitlements       # hardened runtime, no sandbox
    KeepAliveHelper/                 # NOT an Xcode target — built by install.sh
        KeepAliveHelper.swift        # single-file swiftc binary; control socket + VHID client
        com.kevinlay.keepalive.helper.plist
        install.sh
```

## Build paths

- **App**: Xcode or `xcodebuild -project KeepAlive.xcodeproj -scheme KeepAlive -configuration Release build`. No helper target, no Copy Files phase, no embedded binary, no SMAppService.
- **Helper**: `sudo KeepAliveHelper/install.sh` — swiftc-compiles the single file, drops it in `/usr/local/libexec/keepalive-helper`, installs + kickstarts the LaunchDaemon.

The two halves are decoupled by design: helper doesn't have to ship inside the app bundle, doesn't need a matching Team ID, doesn't need notarization for local use. Communication is a 1-byte `AF_UNIX` datagram on `/var/run/keepalive.sock`.

## Signing

- Main app: hardened runtime, automatic signing under Team `QKXV85S73A`. No special entitlements beyond Accessibility for the CGEvent fallback.
- Helper: runs as root, LaunchDaemon-loaded. `install.sh` uses the ambient toolchain's default signing (ad-hoc for `swiftc`), which is fine because it's not loaded by launchd as a bundle — it's just a binary at a fixed path.

## Gate 0 — smoke test the VHID wire protocol

If you suspect Karabiner's wire protocol has drifted, compile just the helper binary and run it directly:

```sh
cd KeepAlive/KeepAliveHelper
swiftc -O KeepAliveHelper.swift -o /tmp/keepalive-helper
sudo /tmp/keepalive-helper &
# in another shell:
printf '\x4E' | nc -u -w0 -U /var/run/keepalive.sock
```

The cursor should twitch 1px right-then-left. If it doesn't, `tail -f /var/log/keepalive-helper.log` — typical failures are:

- **server socket not found** — Karabiner's dext isn't activated. Check `systemextensionsctl list | grep pqrs`.
- **timeout waiting for `pointing_ready`** — wire protocol version mismatch. Current code assumes v5 (Karabiner-DriverKit-VirtualHIDDevice v6.8+). If you're on an older Karabiner, check `VHIDRequest`/`VHIDResponse` enums in `KeepAliveHelper.swift` against the daemon's headers.
- **jiggle succeeds but cursor doesn't move** — driver loaded but not connected. Usually fixes itself after a reboot or Karabiner relaunch.

## Pbxproj hygiene

`project.pbxproj` is checked in with only the files the main-app target needs. If you add a new `.swift` file under `KeepAlive/KeepAlive/`, add it to the `Sources` build phase in Xcode (or hand-edit the pbxproj — IDs follow the `A1xxxxxx` / `A2xxxxxx` convention). Don't add anything under `KeepAliveHelper/` to the Xcode project — it's built separately.

## Troubleshooting

- **Menu bar shows "Helper not installed"** — `ls /var/run/keepalive.sock` should exist. If not, re-run `sudo install.sh`.
- **Helper installed but nudges do nothing** — `sudo launchctl print system/com.kevinlay.keepalive.helper | grep -E 'state|pid'` should show `state = running`. Check `/var/log/keepalive-helper.log` for VHID errors.
- **Screen locks anyway on Intune-managed Mac** — the fallback `CGEvent` path is all that's running. Verify the helper is installed *and* Karabiner's dext is approved — both are required.
