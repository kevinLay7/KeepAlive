import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let powerManager = PowerManager()
    let sessionTimer = SessionTimer()
    let scheduleManager: ScheduleManager

    init() {
        scheduleManager = ScheduleManager(powerManager: powerManager, sessionTimer: sessionTimer)
    }
}

@main
struct KeepAliveApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                powerManager: appState.powerManager,
                sessionTimer: appState.sessionTimer,
                scheduleManager: appState.scheduleManager
            )
        } label: {
            Image(systemName: appState.powerManager.isActive ? "bolt.fill" : "bolt.slash")
        }
        .menuBarExtraStyle(.menu)

        Window("Schedules", id: "schedules") {
            ScheduleListView(scheduleManager: appState.scheduleManager)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
