import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var powerManager: PowerManager
    @ObservedObject var sessionTimer: SessionTimer
    @ObservedObject var scheduleManager: ScheduleManager
    @ObservedObject var karabinerBridge: KarabinerBridge
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        if powerManager.isActive {
            if sessionTimer.isRunning {
                Text("Active — \(sessionTimer.formattedRemaining) remaining")
            } else if let schedule = scheduleManager.activeSchedule {
                Text("Active — \(schedule.name)")
            } else {
                Text("Active — Indefinitely")
            }
            Divider()
        }

        Button(powerManager.isActive ? "Turn Off" : "Turn On Indefinitely") {
            if powerManager.isActive {
                sessionTimer.stop()
                powerManager.deactivate()
            } else {
                powerManager.activate()
            }
        }
        .keyboardShortcut("k", modifiers: [.command])

        Divider()

        Menu("Keep Awake For...") {
            ForEach(SessionTimer.Duration.allCases) { duration in
                Button(duration.label) {
                    powerManager.activate()
                    sessionTimer.start(duration: duration) {
                        powerManager.deactivate()
                    }
                }
            }
        }

        if sessionTimer.isRunning {
            Button("Cancel Timer") {
                sessionTimer.stop()
                powerManager.deactivate()
            }
        }

        Divider()

        Button("Schedules...") {
            openWindow(id: "schedules")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

        if !powerManager.hasAccessibilityPermission {
            Divider()
            Button("⚠️ Grant Accessibility Access…") {
                powerManager.requestAccessibilityPermission()
            }
        }

        Divider()

        Menu("Karabiner Bridge") {
            Text(karabinerBridgeStatusLabel)
            Divider()
            switch karabinerBridge.state {
            case .notRegistered, .registrationFailed:
                Button("Install Helper…") { karabinerBridge.register() }
            case .requiresApproval:
                Button("Open Login Items Settings…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                Button("Re-check Status") {
                    karabinerBridge.refreshStateFromSMAppService()
                }
            case .running, .unresponsive:
                Button("Uninstall Helper") { karabinerBridge.unregister() }
                Button("Refresh Status") {
                    Task { await karabinerBridge.refreshStatus() }
                }
            case .registering:
                Text("Registering…").disabled(true)
            }
        }

        Divider()

        Button("Quit KeepAlive") {
            powerManager.deactivate()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private var karabinerBridgeStatusLabel: String {
        switch karabinerBridge.state {
        case .notRegistered:
            return "Not installed"
        case .registering:
            return "Registering…"
        case .requiresApproval:
            return "Waiting for approval in System Settings"
        case .registrationFailed(let msg):
            return "Failed: \(msg)"
        case .running:
            if karabinerBridge.pointingReady { return "Active — driver ready" }
            if karabinerBridge.driverConnected { return "Active — initializing…" }
            return "Active — waiting for driver"
        case .unresponsive(let msg):
            return "Unresponsive: \(msg)"
        }
    }
}
