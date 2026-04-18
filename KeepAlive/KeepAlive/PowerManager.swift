import AppKit
import Combine
import IOKit.pwr_mgt
import CoreGraphics

@MainActor
class PowerManager: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var hasAccessibilityPermission: Bool = false

    private var displayAssertionID: IOPMAssertionID = 0
    private var sleepAssertionID: IOPMAssertionID = 0
    private var reassertCancellable: AnyCancellable?
    private var permissionPollCancellable: AnyCancellable?
    private var virtualHID: VirtualHIDDevice?
    private let karabinerBridge: KarabinerBridge?

    init(karabinerBridge: KarabinerBridge? = nil) {
        self.karabinerBridge = karabinerBridge
        hasAccessibilityPermission = AXIsProcessTrusted()
        // Poll until granted so the UI updates without a restart
        if !hasAccessibilityPermission {
            startPermissionPolling()
        }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        permissionPollCancellable = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let granted = AXIsProcessTrusted()
                if granted {
                    self.hasAccessibilityPermission = true
                    self.permissionPollCancellable?.cancel()
                    self.permissionPollCancellable = nil
                }
            }
    }

    func activate() {
        guard !isActive else { return }
        acquireAssertions()
        // Try to stand up a virtual HID keyboard; falls back to CGEvent if unavailable.
        virtualHID = VirtualHIDDevice()
        isActive = true
        startJiggle()
        startReassertTimer()
    }

    func deactivate() {
        guard isActive else { return }
        releaseAssertions()
        stopJiggle()
        stopReassertTimer()
        virtualHID = nil
        isActive = false
    }

    func toggle() {
        if isActive { deactivate() } else { activate() }
    }

    // MARK: - Assertions

    private func acquireAssertions() {
        let reason = "KeepAlive preventing sleep" as CFString
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displayAssertionID
        )
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )
    }

    private func releaseAssertions() {
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }

    // MARK: - Periodic re-assertion

    private func startReassertTimer() {
        // IOPMAssertions don't expire on their own; refresh hourly as a watchdog
        // in case something external releases them (rare, but cheap to guard against).
        reassertCancellable = Timer.publish(every: 3600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.releaseAssertions()
                    self.acquireAssertions()
                }
            }
    }

    private func stopReassertTimer() {
        reassertCancellable?.cancel()
        reassertCancellable = nil
    }

    // MARK: - Jiggle
    //
    // Two design choices worth calling out:
    //   1. We only nudge when real HID idle exceeds `idleThreshold`, so typing/clicking
    //      never produces a synthetic event. Matches Amphetamine's "Inactivity Delay".
    //   2. We skip nudges while the screen is locked — a jiggler that keeps firing post-lock
    //      is the canonical "mouse jiggler" signature in EDR hunting queries.
    // Interval is jittered ±20% so the cadence doesn't look like a metronome.

    // Teams on macOS flips "Away" at ~5 minutes of real HID idle, so we nudge before that.
    // Check every ~2 minutes; act if the user has actually been idle for 3 minutes.
    private let baseInterval: TimeInterval = 120
    private let idleThreshold: TimeInterval = 180

    private var jiggleTimer: DispatchSourceTimer?

    private func startJiggle() {
        scheduleNextJiggle(initial: true)
    }

    private func stopJiggle() {
        jiggleTimer?.cancel()
        jiggleTimer = nil
    }

    private func scheduleNextJiggle(initial: Bool = false) {
        let jitter = Double.random(in: -0.2...0.2)
        let delay = initial ? 5 : baseInterval * (1 + jitter)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.maybeNudge()
            self.scheduleNextJiggle()
        }
        timer.resume()
        jiggleTimer = timer
    }

    private func maybeNudge() {
        // Skip if the screen is locked — post-lock jiggles are the EDR signature.
        if isScreenLocked() { return }
        // Skip unless the user has actually been idle long enough to matter.
        let realIdle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .init(rawValue: ~0)!
        )
        if realIdle < idleThreshold { return }
        nudge()
    }

    private func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private func nudge() {
        declareUserActivity()

        // Tier 1: Karabiner VHID bridge (real DriverKit HID device — works on
        // Intune-managed Macs where synthetic CGEvents don't reset the lock timer).
        // Async; fallback only fires if the bridge isn't running or reports failure.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let bridge = self.karabinerBridge, await bridge.nudge() {
                return
            }
            self.fallbackNudge()
        }
    }

    private func fallbackNudge() {
        // Tier 2: local IOHIDUserDevice (usually fails on macOS 15+ without
        // the com.apple.developer.hid.virtual.device entitlement).
        // Tier 3: CGEvent mouse + F15/F14.
        if let virtualHID {
            virtualHID.tapF20()
        } else {
            nudgeMouse()
            tapInvisibleKey()
        }
    }

    private func declareUserActivity() {
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("KeepAlive user activity" as CFString, kIOPMUserActiveLocal, &assertionID)
    }

    private func nudgeMouse() {
        let currentPos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        // NSEvent uses bottom-left origin; CGEvent uses top-left
        let cgY = screenHeight - currentPos.y

        let offset: CGFloat = 1
        let nudged = CGPoint(x: currentPos.x + offset, y: cgY + offset)
        let original = CGPoint(x: currentPos.x, y: cgY)

        // Use the HID system source so the event updates IOHIDSystem's HIDIdleTime
        // (a nil source posts a private event that doesn't reset the screensaver timer).
        let src = CGEventSource(stateID: .hidSystemState)
        if let moveOut = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: nudged, mouseButton: .left) {
            moveOut.post(tap: .cgSessionEventTap)
        }
        if let moveBack = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left) {
            moveBack.post(tap: .cgSessionEventTap)
        }
    }

    private func tapInvisibleKey() {
        // F15 (0x71) = brightness up, F14 (0x6B) = brightness down on Apple keyboards.
        // Pressing them as a pair nets to zero brightness drift while guaranteeing
        // two real HID keypress events that reset HIDIdleTime and satisfy Teams.
        let src = CGEventSource(stateID: .hidSystemState)
        for key in [CGKeyCode(0x71), CGKeyCode(0x6B)] {
            CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)?
                .post(tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)?
                .post(tap: .cgSessionEventTap)
        }
    }
}
