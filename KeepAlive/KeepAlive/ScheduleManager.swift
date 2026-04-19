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
        let totalMinutes = Int(ceil(Double(secs) / 60.0))
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        let newValue: String
        if h > 0 {
            newValue = String(format: "%dh %dm", h, m)
        } else {
            newValue = String(format: "%dm", max(m, 0))
        }
        if newValue != scheduleFormattedRemaining {
            scheduleFormattedRemaining = newValue
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
