import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var powerManager: PowerManager
    @ObservedObject var sessionTimer: SessionTimer
    @ObservedObject var scheduleManager: ScheduleManager
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

        Divider()

        Button("Quit KeepAlive") {
            powerManager.deactivate()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}
