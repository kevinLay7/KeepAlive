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
    private var jiggleCancellable: AnyCancellable?
    private var reassertCancellable: AnyCancellable?
    private var permissionPollCancellable: AnyCancellable?

    init() {
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
        isActive = true
        startJiggle()
        startReassertTimer()
    }

    func deactivate() {
        guard isActive else { return }
        releaseAssertions()
        stopJiggle()
        stopReassertTimer()
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
        reassertCancellable = Timer.publish(every: 120, on: .main, in: .common)
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

    private func startJiggle() {
        // Nudge immediately on activation, then every 15 seconds
        nudge()
        jiggleCancellable = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.nudge()
                }
            }
    }

    private func stopJiggle() {
        jiggleCancellable?.cancel()
        jiggleCancellable = nil
    }

    private func nudge() {
        declareUserActivity()
        nudgeMouse()
        tapInvisibleKey()
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

        // Move away then back so the cursor ends up where it started
        if let moveOut = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: nudged, mouseButton: .left) {
            moveOut.post(tap: .cgSessionEventTap)
        }
        if let moveBack = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left) {
            moveBack.post(tap: .cgSessionEventTap)
        }
    }

    private func tapInvisibleKey() {
        // F15 (0x71) — real keypress that registers as user activity
        // but doesn't produce visible output in any app.
        // Modifier-only keys (shift) are often ignored by activity detectors.
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x71, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x71, keyDown: false)
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
