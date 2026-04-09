import Foundation
import Combine

@MainActor
class ScheduleManager: ObservableObject {
    @Published var schedules: [Schedule] = [] {
        didSet { save() }
    }
    @Published private(set) var activeSchedule: Schedule?
    @Published private(set) var scheduleFormattedRemaining: String = ""

    private var checkCancellable: AnyCancellable?
    private var countdownCancellable: AnyCancellable?
    private let userDefaultsKey = "keepalive.schedules"

    weak var powerManager: PowerManager?
    weak var sessionTimer: SessionTimer?

    init(powerManager: PowerManager, sessionTimer: SessionTimer) {
        self.powerManager = powerManager
        self.sessionTimer = sessionTimer
        load()
        startChecking()
    }

    func addSchedule(_ schedule: Schedule) {
        schedules.append(schedule)
    }

    func updateSchedule(_ schedule: Schedule) {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        }
    }

    func deleteSchedule(id: UUID) {
        schedules.removeAll { $0.id == id }
        if activeSchedule?.id == id {
            activeSchedule = nil
            deactivate()
        }
    }

    func checkSchedules() {
        let matchingSchedule = schedules.first { $0.isActiveNow() }

        if let match = matchingSchedule {
            if activeSchedule?.id != match.id {
                activeSchedule = match
                sessionTimer?.stop()
                powerManager?.activate()
                startCountdown()
            }
        } else if activeSchedule != nil {
            activeSchedule = nil
            stopCountdown()
            deactivate()
        }
    }

    private func startCountdown() {
        stopCountdown()
        updateScheduleCountdown()
        countdownCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.updateScheduleCountdown()
                }
            }
    }

    private func stopCountdown() {
        countdownCancellable?.cancel()
        countdownCancellable = nil
        scheduleFormattedRemaining = ""
    }

    private func updateScheduleCountdown() {
        guard let schedule = activeSchedule else { stopCountdown(); return }
        let secs = schedule.secondsUntilEnd
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 {
            scheduleFormattedRemaining = String(format: "%d:%02d:%02d", h, m, s)
        } else {
            scheduleFormattedRemaining = String(format: "%02d:%02d", m, s)
        }
    }

    private func deactivate() {
        if sessionTimer?.isRunning != true {
            powerManager?.deactivate()
        }
    }

    private func startChecking() {
        checkSchedules()
        checkCancellable = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.checkSchedules()
                }
            }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(schedules) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([Schedule].self, from: data) else { return }
        schedules = decoded
    }
}
