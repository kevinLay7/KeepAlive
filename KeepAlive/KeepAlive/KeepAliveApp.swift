import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    let powerManager = PowerManager()
    let sessionTimer = SessionTimer()
    let scheduleManager: ScheduleManager
    private var cancellables = Set<AnyCancellable>()

    init() {
        scheduleManager = ScheduleManager(powerManager: powerManager, sessionTimer: sessionTimer)

        // Forward sub-object changes so MenuBarExtra label re-renders
        powerManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        sessionTimer.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        scheduleManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
            if appState.powerManager.isActive {
                if appState.sessionTimer.isRunning {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                        Text(appState.sessionTimer.formattedRemaining)
                            .monospacedDigit()
                    }
                } else if !appState.scheduleManager.scheduleFormattedRemaining.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                        Text(appState.scheduleManager.scheduleFormattedRemaining)
                            .monospacedDigit()
                    }
                } else {
                    Image(systemName: "bolt.fill")
                }
            } else {
                Image(systemName: "bolt.slash")
            }
        }
        .menuBarExtraStyle(.menu)

        Window("Schedules", id: "schedules") {
            ScheduleListView(scheduleManager: appState.scheduleManager)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
