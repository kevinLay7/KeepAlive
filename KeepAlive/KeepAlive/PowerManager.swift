import AppKit
import Combine
import IOKit.pwr_mgt
import CoreGraphics

@MainActor
class PowerManager: ObservableObject {
    @Published private(set) var isActive = false

    private var assertionID: IOPMAssertionID = 0
    private var jiggleCancellable: AnyCancellable?
    private var jiggleOffset = false

    func activate() {
        guard !isActive else { return }
        let reason = "KeepAlive preventing sleep" as CFString
        let success = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if success == kIOReturnSuccess {
            isActive = true
            startMouseJiggle()
        }
    }

    func deactivate() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        stopMouseJiggle()
        isActive = false
    }

    func toggle() {
        if isActive { deactivate() } else { activate() }
    }

    private func startMouseJiggle() {
        jiggleCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.nudgeMouse()
                }
            }
    }

    private func stopMouseJiggle() {
        jiggleCancellable?.cancel()
        jiggleCancellable = nil
    }

    private func nudgeMouse() {
        let currentPos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        // NSEvent uses bottom-left origin; CGEvent uses top-left
        let cgY = screenHeight - currentPos.y

        let offset: CGFloat = jiggleOffset ? -1 : 1
        jiggleOffset.toggle()

        let destination = CGPoint(x: currentPos.x + offset, y: cgY + offset)
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: destination, mouseButton: .left) {
            moveEvent.post(tap: .cgSessionEventTap)
        }
    }
}
