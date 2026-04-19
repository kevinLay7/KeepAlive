import Foundation
import Combine

@MainActor
class SessionTimer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var selectedDuration: Duration?
    @Published private(set) var formattedRemaining: String = ""

    private(set) var remainingSeconds = 0
    private var timerCancellable: AnyCancellable?

    enum Duration: Int, CaseIterable, Identifiable {
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case thirtyMinutes = 1800
        case fortyFiveMinutes = 2700
        case oneHour = 3600
        case twoHours = 7200
        case threeHours = 10800
        case fourHours = 14400
        case eightHours = 28800

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .fiveMinutes: return "5 Minutes"
            case .fifteenMinutes: return "15 Minutes"
            case .thirtyMinutes: return "30 Minutes"
            case .fortyFiveMinutes: return "45 Minutes"
            case .oneHour: return "1 Hour"
            case .twoHours: return "2 Hours"
            case .threeHours: return "3 Hours"
            case .fourHours: return "4 Hours"
            case .eightHours: return "8 Hours"
            }
        }
    }

    func start(duration: Duration, onExpire: @escaping @MainActor () -> Void) {
        stop()
        selectedDuration = duration
        remainingSeconds = duration.rawValue
        isRunning = true
        refreshFormatted()

        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.remainingSeconds -= 1
                    if self.remainingSeconds <= 0 {
                        self.stop()
                        onExpire()
                    } else {
                        self.refreshFormatted()
                    }
                }
            }
    }

    func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil
        isRunning = false
        remainingSeconds = 0
        selectedDuration = nil
        formattedRemaining = ""
    }

    private func refreshFormatted() {
        let totalMinutes = Int(ceil(Double(remainingSeconds) / 60.0))
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        let newValue: String
        if h > 0 {
            newValue = String(format: "%dh %dm", h, m)
        } else {
            newValue = String(format: "%dm", max(m, 0))
        }
        if newValue != formattedRemaining {
            formattedRemaining = newValue
        }
    }
}
