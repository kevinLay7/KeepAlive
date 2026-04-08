import Foundation
import Combine

@MainActor
class SessionTimer: ObservableObject {
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isRunning = false
    @Published private(set) var selectedDuration: Duration?

    private var timerCancellable: AnyCancellable?

    enum Duration: Int, CaseIterable, Identifiable {
        case thirtyMinutes = 1800
        case oneHour = 3600
        case twoHours = 7200
        case fourHours = 14400

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .thirtyMinutes: return "30 Minutes"
            case .oneHour: return "1 Hour"
            case .twoHours: return "2 Hours"
            case .fourHours: return "4 Hours"
            }
        }
    }

    func start(duration: Duration, onExpire: @escaping @MainActor () -> Void) {
        stop()
        selectedDuration = duration
        remainingSeconds = duration.rawValue
        isRunning = true

        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.remainingSeconds -= 1
                    if self.remainingSeconds <= 0 {
                        self.stop()
                        onExpire()
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
    }

    var formattedRemaining: String {
        let h = remainingSeconds / 3600
        let m = (remainingSeconds % 3600) / 60
        let s = remainingSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
