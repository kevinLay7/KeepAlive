# KeepAlive — Xcode target wiring for the Karabiner bridge

Follow these once to add the privileged helper target. Takes ~10 min. Do this
after committing your current clean state so you can `git reset --hard` if
anything goes sideways.

## ⛔ Gate 0 — verify the wire protocol works BEFORE you touch Xcode

All of the Xcode work below is stacked on the assumption that the VHID
wire protocol is correct for your machine's installed daemon version.
**Verify that first** — it's 30 seconds and saves hours if anything's off.

```sh
cd KeepAlive/KeepAliveHelper
swiftc main.swift -o khelper
sudo ./khelper
```

Expected log:
```
found server socket: .../vhidd_server/<hex>.sock
→ sent request=virtualHIDPointingInitialize bytes=5
← driverConnected value=1
← virtualHIDPointingReady value=1
pointing ready — sending +1 dx
sending -1 dx
done — cursor should have twitched right-then-left by 1px.
```

**And your cursor should visibly twitch.** If it doesn't, or `virtualHIDPointingReady`
never arrives, stop here and paste the log — proceeding past this gate wastes time.

Note: `KeepAliveHelper/main.swift` as written is a standalone CLI that also serves
as the helper when compiled with `VHIDClient.swift` + the shared protocol by Xcode.
The single-file `swiftc` command above builds only the CLI smoke-test version, which
is exactly what you want for Gate 0.

**Actually — a caveat**: the standalone smoke test lives in the Git history of this
work. The current `main.swift` is already the XPC-listener version and won't run
cleanly with plain `swiftc main.swift`. To do Gate 0 you have two options:

1. Check out the earlier commit where `main.swift` was standalone, run it, then
   come back.
2. Use this one-liner substitute that exercises the exact same `VHIDClient` class:
   ```sh
   cd KeepAlive/KeepAliveHelper
   cat > smoketest.swift <<'EOF'
   import Foundation
   let c = try VHIDClient()
   c.initializePointing()
   Thread.sleep(forTimeInterval: 1.5)
   print("driverConnected=\(c.driverConnected) pointingReady=\(c.pointingReady)")
   let (ok, err) = c.nudge()
   print("nudge ok=\(ok) err=\(err ?? "nil")")
   Thread.sleep(forTimeInterval: 0.5)
   EOF
   swiftc smoketest.swift VHIDClient.swift -o smoketest
   sudo ./smoketest
   rm smoketest.swift smoketest
   ```
   Expected: `pointingReady=true`, `nudge ok=true`, cursor twitches.

## 1. Set the Development Team on the main app

1. Open `KeepAlive.xcodeproj` in Xcode.
2. Select the project in the navigator → **KeepAlive** target → **Signing & Capabilities**.
3. Under **Team**, pick your paid Apple Developer team. (Team ID: `QKXV85S73A`.)
4. Add the **Hardened Runtime** capability if not already present (required for SMAppService).
5. Set **Code Signing Entitlements** to `KeepAlive/KeepAlive.entitlements` (the file is already on disk).

## 2. Add the shared protocol to the main app target

1. In the navigator, right-click the `KeepAlive` group → **Add Files to "KeepAlive"…**.
2. Navigate to `KeepAlive/Shared/` and select `KarabinerHelperProtocol.swift`.
3. In the dialog, **uncheck** "Copy items if needed". Under **Add to targets**, check **both**:
    - ☑ KeepAlive
    - ☑ KeepAliveHelper (will exist after step 3; re-do this after creating the helper target)

## 3. Add the new helper target

1. **File → New → Target…**
2. Pick **macOS → Command Line Tool**. Click **Next**.
3. Fill in:
    - **Product Name**: `com.kevinlay.keepalive.helper`
    - **Team**: same developer team from step 1
    - **Language**: Swift
    - Leave **Bundle Identifier** as auto-derived (`com.kevinlay.keepalive.com.kevinlay.keepalive.helper` — Xcode will let you set the exact value in Build Settings after).
4. Click **Finish**. Xcode will offer to activate the new scheme — say **Activate**.

**Immediately fix the bundle identifier**: target → **Build Settings** → search "Product Bundle Identifier" → set `PRODUCT_BUNDLE_IDENTIFIER` = `com.kevinlay.keepalive.helper`.

## 4. Delete the auto-generated `main.swift` and link the real sources

Xcode auto-creates a `main.swift` in a new group for the new target. Delete it (Move to Trash).

Now add our files to the helper target:

1. Right-click the new helper group → **Add Files to "KeepAlive"…** (the top-level project).
2. Navigate to `KeepAlive/KeepAliveHelper/` and select:
    - `main.swift`
    - `VHIDClient.swift`
3. In the dialog: **uncheck** "Copy items if needed". **Add to targets**: ☑ **KeepAliveHelper only** (NOT KeepAlive).

Also add the shared protocol to this target now if you didn't in step 2:
- Select `Shared/KarabinerHelperProtocol.swift` → File Inspector → ☑ KeepAliveHelper under Target Membership.

## 5. Configure the helper target's signing & entitlements

Select the `com.kevinlay.keepalive.helper` target → **Signing & Capabilities**:

1. **Team**: your developer team.
2. **Signing Certificate**: Development (while iterating) or Developer ID (for distributing).
3. Add **Hardened Runtime** capability.
4. Set **Code Signing Entitlements** to `KeepAliveHelper/KeepAliveHelper.entitlements`.

In **Build Settings**:

- `SKIP_INSTALL` = `NO`
- `INSTALL_PATH` = `$(LOCAL_APPS_DIR)` — irrelevant since it's copied; default is fine.
- `OTHER_CODE_SIGN_FLAGS` add `--timestamp` (for notarization).

## 6. Embed the helper binary into the main app

The main app target needs two Copy Files phases so `xcodebuild` packages the helper + its launchd plist into `KeepAlive.app/Contents/…`:

Select the **KeepAlive** target → **Build Phases** → **+** → **New Copy Files Phase** (do this twice):

**Copy Files phase #1: Embed helper binary**
- **Name** (double-click phase header): "Embed Helper"
- **Destination**: "Executables" → custom path: `Contents/MacOS`  
  (or pick "Wrapper" with subpath `Contents/MacOS`)
- **Code Sign On Copy**: ☑
- Drag the helper target's product (`com.kevinlay.keepalive.helper`) from the **Products** group into this phase's file list.

**Copy Files phase #2: Embed LaunchDaemon plist**
- **Name**: "Embed LaunchDaemon Plist"
- **Destination**: "Wrapper" with subpath: `Contents/Library/LaunchDaemons`
- Drag `KeepAliveHelper/com.kevinlay.keepalive.helper.plist` into the file list.

Also add an implicit target dependency:
- KeepAlive target → **Build Phases** → **Target Dependencies** → **+** → add `com.kevinlay.keepalive.helper`.

## 7. Build & verify structure

Build the app (⌘B). In the Products group, right-click `KeepAlive.app` → **Show in Finder**. Right-click the `.app` → **Show Package Contents**. Verify:

```
KeepAlive.app/Contents/
    MacOS/
        KeepAlive
        com.kevinlay.keepalive.helper
    Library/
        LaunchDaemons/
            com.kevinlay.keepalive.helper.plist
```

Quick sanity check from Terminal:

```sh
codesign -dvv /path/to/KeepAlive.app/Contents/MacOS/com.kevinlay.keepalive.helper 2>&1 | grep -E 'Team|Authority'
```

Should show `TeamIdentifier=QKXV85S73A` and a `Developer ID Application` or `Apple Development` authority.

## 8. First run & registration

1. Run the app from Xcode (⌘R). The menu bar icon appears.
2. Click the icon → **Karabiner Bridge → Install Helper…**
3. macOS will prompt for admin password and open **System Settings → Login Items & Extensions**. Toggle the helper on if it's not already.
4. Back in the menu: **Karabiner Bridge → Refresh Status**. Label should become "Active — driver ready" within a second or two.
5. Turn KeepAlive on (⌘K). Let your Mac idle > 3 min. When the nudge timer fires, the cursor should twitch 1px right-then-left, and the managed screen lock should no longer fire.

## Troubleshooting

- **Helper state stuck at "requires user approval"**: open System Settings → Login Items & Extensions → under Allow in the Background, enable KeepAlive's helper.
- **"Failed: Operation not permitted" when registering**: the app isn't properly code-signed or the plist isn't at `Contents/Library/LaunchDaemons/<Label>.plist`. Double-check the Copy Files phase destination.
- **Helper runs but `driver_connected=0`**: the Karabiner DriverKit sysex isn't loaded. Verify with `systemextensionsctl list | grep pqrs`. Reinstall Karabiner-Elements if missing.
- **Logs**: the helper writes to `/tmp/com.kevinlay.keepalive.helper.{out,err}.log` while running. Also see `log stream --predicate 'process == "com.kevinlay.keepalive.helper"'`.

## What's shipped on disk (summary)

```
KeepAlive/
    KeepAlive/
        KarabinerBridge.swift            # XPC client, state machine
        KeepAlive.entitlements           # hardened runtime, no sandbox
        (+ existing files, PowerManager.swift now calls bridge)
    KeepAliveHelper/                     # NEW target
        main.swift                       # XPC listener entry point
        VHIDClient.swift                 # VHID daemon protocol client
        com.kevinlay.keepalive.helper.plist
        KeepAliveHelper.entitlements
        khelper                          # (dev build artifact, ignore)
    Shared/                              # NEW group, in BOTH targets
        KarabinerHelperProtocol.swift
    XCODE_SETUP.md                       # this file
```
