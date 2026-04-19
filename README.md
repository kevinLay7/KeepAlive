# KeepAlive

Minimal macOS menu-bar app. Keeps your Mac awake and your presence "active" so screen lock, Teams/Slack "Away", and MDM inactivity timers don't fire while you're at lunch or in a meeting.

## What it does

When active:

1. Holds `kIOPMAssertionTypeNoDisplaySleep` + `NoIdleSleep` so display/system don't idle-sleep.
2. Once real HID idle exceeds ~3 min, sends a 1-byte nudge to a root LaunchDaemon every ~2 min (jittered ±20%).
3. Helper forwards nudge to the **Karabiner-DriverKit-VirtualHIDDevice** daemon, which posts a real `±1`-pixel pointing report through the DriverKit dext. Kernel sees a real HID event → `HIDIdleTime` resets → macOS, Teams, Slack, Intune all see you as present.
4. If Karabiner/helper isn't installed, falls back to synthetic `CGEvent` (F15/F14 + mouse nudge). Good enough for Teams, **not** enough for Intune-managed Macs.
5. Skips nudges while the screen is locked — post-lock jiggle is the canonical EDR signature.

No keystrokes into your focused app, no cursor jiggling, no network, no telemetry.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ (to build)
- **Karabiner-DriverKit-VirtualHIDDevice v6.8+** with the dext activated — this is what lets us post *real* HID events instead of synthetic ones. Without it the app still runs but drops to the CGEvent fallback.

## Install

### 1. Install Karabiner's virtual HID driver

Only the driver is required — not full Karabiner-Elements.

```bash
brew install --cask karabiner-elements
```

On first launch, approve the DriverKit system extension in **System Settings → Privacy & Security → Allow System Software**, then reboot if prompted. You can verify the driver is live by checking:

```bash
ls "/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server/"*.sock
```

At least one `.sock` file should exist.

### 2. Build the app

```bash
git clone https://github.com/<your-org>/keepalive.git
cd keepalive/KeepAlive
xcodebuild -project KeepAlive.xcodeproj -scheme KeepAlive \
           -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/KeepAlive.app /Applications/
open /Applications/KeepAlive.app
```

Or open `KeepAlive.xcodeproj` in Xcode and press ⌘R.

### 3. Install the root helper daemon

The helper is a tiny swift binary that runs as root so it can reach Karabiner's root-only VHID socket. It listens on `/var/run/keepalive.sock` for 1-byte nudges from the app.

```bash
sudo KeepAliveHelper/install.sh
```

This script:

- `swiftc`-compiles `KeepAliveHelper/KeepAliveHelper.swift` → `/usr/local/libexec/keepalive-helper`
- Installs the LaunchDaemon plist → `/Library/LaunchDaemons/com.kevinlay.keepalive.helper.plist`
- `launchctl bootstrap`s + kickstarts the daemon

Re-run the same script to update after any helper changes; it cleanly boots out the old instance first.

Verify:

```bash
sudo launchctl print system/com.kevinlay.keepalive.helper | grep -E 'state|pid'
tail -f /var/log/keepalive-helper.log
```

### 4. Grant Accessibility (fallback path only)

On first launch the app will prompt for **Accessibility** (System Settings → Privacy & Security → Accessibility). This is only required for the `CGEvent` fallback — the Karabiner path doesn't need it. Granting is still recommended so the app degrades cleanly if the helper or driver goes away.

## Uninstall

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.kevinlay.keepalive.helper.plist
sudo rm /Library/LaunchDaemons/com.kevinlay.keepalive.helper.plist
sudo rm /usr/local/libexec/keepalive-helper
rm -rf /Applications/KeepAlive.app
```

Leave Karabiner's driver alone unless you're uninstalling it separately.

## Architecture

```
 ┌──────────────────┐   1-byte UDP           ┌──────────────────┐
 │ KeepAlive.app    │ ─────────────────────▶ │ keepalive-helper │
 │ (user, menu bar) │  /var/run/keepalive    │ (root LaunchDmn) │
 └──────────────────┘                        └────────┬─────────┘
                                                      │ VHID wire v5
                                                      ▼
                                 ┌──────────────────────────────────┐
                                 │ Karabiner-DriverKit-VHID daemon  │
                                 │   /Library/Application Support/  │
                                 │   org.pqrs/.../vhidd_server/*    │
                                 └────────────┬─────────────────────┘
                                              │ dext
                                              ▼
                                         IOHIDSystem
```

- **Power assertions** (`IOPMAssertionCreateWithName`) handle display/system sleep. They don't affect the screensaver/lock timer — that's driven by HID idle.
- **Karabiner VHID bridge** is the primary activity path. Real HID pointing reports reset `HIDIdleTime` even on Intune-locked Macs, because the driver lives in kernel HID space, not `CGEvent` space.
- **CGEvent fallback** (brightness F15/F14 pair + 1px mouse nudge) kicks in only if the helper socket is missing. Resets HIDIdleTime on unmanaged Macs, defeats Teams "Away", but Intune's 900 s screen-lock timer ignores it.

See `KeepAlive/XCODE_SETUP.md` for project-structure notes if you're editing the Xcode project itself.

## Scheduling

Menu bar → **Schedules…** — simple editor for auto-activation windows. Default is Mon–Fri 9–5.

## Corporate-managed Macs

If your Mac is MDM-managed (Intune, Jamf, Kandji), it likely has an inactivity-lock policy. The Karabiner path defeats it by design. That may violate your acceptable-use policy — talk to IT before deploying widely.

## License

MIT.
