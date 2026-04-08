import Foundation

struct Schedule: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var days: Set<Weekday>
    var startTime: TimeOfDay
    var endTime: TimeOfDay
    var isEnabled: Bool

    enum Weekday: Int, Codable, CaseIterable, Identifiable, Comparable {
        case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

        var id: Int { rawValue }

        var shortName: String {
            switch self {
            case .sunday: return "Sun"
            case .monday: return "Mon"
            case .tuesday: return "Tue"
            case .wednesday: return "Wed"
            case .thursday: return "Thu"
            case .friday: return "Fri"
            case .saturday: return "Sat"
            }
        }

        static func < (lhs: Weekday, rhs: Weekday) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct TimeOfDay: Codable, Equatable {
        var hour: Int
        var minute: Int

        var date: Date {
            Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
        }

        init(hour: Int, minute: Int) {
            self.hour = hour
            self.minute = minute
        }

        init(from date: Date) {
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            self.hour = components.hour ?? 0
            self.minute = components.minute ?? 0
        }

        var totalMinutes: Int { hour * 60 + minute }

        var formatted: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        }
    }

    func isActiveNow() -> Bool {
        guard isEnabled else { return false }
        let now = Date()
        let calendar = Calendar.current
        let weekdayComponent = calendar.component(.weekday, from: now)
        guard let weekday = Weekday(rawValue: weekdayComponent), days.contains(weekday) else {
            return false
        }
        let currentMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let start = startTime.totalMinutes
        let end = endTime.totalMinutes

        if start < end {
            return currentMinutes >= start && currentMinutes < end
        } else if start > end {
            // Overnight schedule (e.g., 10 PM to 6 AM)
            return currentMinutes >= start || currentMinutes < end
        }
        return false
    }

    var daysDescription: String {
        let sorted = days.sorted()
        if sorted.count == 7 { return "Every day" }
        if sorted == [.monday, .tuesday, .wednesday, .thursday, .friday] { return "Weekdays" }
        if sorted == [.sunday, .saturday] { return "Weekends" }
        return sorted.map(\.shortName).joined(separator: ", ")
    }

    static func defaultSchedule() -> Schedule {
        Schedule(
            name: "Work Hours",
            days: Set([.monday, .tuesday, .wednesday, .thursday, .friday]),
            startTime: TimeOfDay(hour: 9, minute: 0),
            endTime: TimeOfDay(hour: 17, minute: 0),
            isEnabled: true
        )
    }
}
