import Foundation
import Combine

@MainActor
class ScheduleManager: ObservableObject {
    @Published var schedules: [Schedule] = [] {
        didSet { save() }
    }
    @Published private(set) var activeSchedule: Schedule?

    private var checkCancellable: AnyCancellable?
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
            }
        } else if activeSchedule != nil {
            activeSchedule = nil
            deactivate()
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
