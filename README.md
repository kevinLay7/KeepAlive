# KeepAlive

A minimal macOS menu-bar app that keeps your Mac awake and your presence "active" — useful when you step away from your desk for lunch, meetings, or long builds and don't want your screen to lock, your status to flip to Away, or your session to time out.

## What it does

When active, KeepAlive:

1. Holds `IOPMAssertionTypeNoDisplaySleep` and `NoIdleSleep` power assertions so the display and system don't sleep on their own.
2. Once you've actually been idle for ~3 minutes, posts a brightness-up + brightness-down keypress pair every ~2 minutes (jittered). This resets `IOHIDSystem`'s idle counter so macOS, Teams, Slack, and similar tools see you as present without any drift in brightness, focus, or cursor position.
3. Stops posting any synthetic events while the screen is locked.

What it does **not** do: no keystrokes into your focused app, no cursor jiggling, no network calls, no telemetry, no background data collection.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ to build

## Build and run

```bash
git clone https://github.com/<your-org>/keepalive.git
cd keepalive/KeepAlive
xcodebuild -scheme KeepAlive -configuration Release build
cp -R "$(xcodebuild -scheme KeepAlive -configuration Release -showBuildSettings \
    | awk -F' = ' '/ CONFIGURATION_BUILD_DIR /{print $2}')/KeepAlive.app" /Applications/
open /Applications/KeepAlive.app
```

Or just open `KeepAlive.xcodeproj` in Xcode and press ⌘R.

On first launch, grant **Accessibility** when prompted (System Settings → Privacy & Security → Accessibility). This is required for `CGEventPost` to reach the HID event system.

## How it works

KeepAlive combines two independent mechanisms so it covers all the common ways macOS decides you're idle:

- **Power assertions** (`IOPMAssertionCreateWithName`) handle display sleep and system idle sleep. They do *not* affect the screensaver/lock timer, which is driven by HID idle time, not display state.
- **Synthetic HID events** (`CGEventPost` with `.hidSystemState` source) reset the HID idle counter so the screensaver, Teams "Away" timer, and MDM-enforced inactivity locks don't fire.

A check runs every ~2 minutes (jittered ±20%). If real HID idle time is below 3 minutes, nothing happens — you're using the machine. If it's above 3 minutes *and* the screen isn't locked, a single F15 (brightness up) + F14 (brightness down) pair is posted. Net brightness change is zero, but two real keypress events reach the kernel.

There's also a prototype virtual-HID path in `VirtualHIDDevice.swift` that attempts to register a virtual keyboard via `IOHIDUserDeviceCreate`. On macOS 11+, virtual *keyboard* devices require the `com.apple.developer.hid.virtual.device` entitlement, which Apple only grants to specific developers, so this path no-ops for locally-signed builds and the `CGEvent` path carries the load.

## Scheduling

KeepAlive has a simple schedule editor (menu bar → Schedules…) for auto-activating during working hours. Default is Mon–Fri 9–5.

## A note on corporate-managed Macs

If your Mac is managed by MDM (Intune, Jamf, Kandji, etc.), there's likely an inactivity-lock policy in place. KeepAlive defeats it by design. This is fine for personal convenience, but if your employer has a legitimate security reason for that policy — customer data exposure, SOC2 requirements, insurance — using this tool may violate your acceptable-use agreement. Talk to your IT team before deploying it widely.

## License

MIT.
