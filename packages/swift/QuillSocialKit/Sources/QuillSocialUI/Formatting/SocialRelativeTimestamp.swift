import Foundation

struct SocialRelativeTimestamp {
    enum Unit: String {
        case second = "s", minute = "m", hour = "h", day = "d", week = "w", month = "mo", year = "y"

        var component: Calendar.Component {
            switch self {
            case .second: .second
            case .minute: .minute
            case .hour: .hour
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }
    }

    let amount: Int
    let unit: Unit

    init(date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) {
        let seconds = max(0, now.timeIntervalSince(date))
        let calendarAge = calendar.dateComponents([.year, .month], from: min(date, now), to: now)
        if let years = calendarAge.year, years > 0 {
            amount = years; unit = .year
        } else if let months = calendarAge.month, months > 0 {
            amount = months; unit = .month
        } else {
            let interval: Double
            switch seconds {
            case 604_800...: unit = .week; interval = 604_800
            case 86_400...: unit = .day; interval = 86_400
            case 3_600...: unit = .hour; interval = 3_600
            case 60...: unit = .minute; interval = 60
            default: unit = .second; interval = 1
            }
            amount = Int(seconds / interval)
        }
    }

    var text: String { "\(amount.formatted(.number.grouping(.never)))\(unit.rawValue)" }

    var accessibilityText: String {
        var components = DateComponents()
        components.setValue(-amount, for: unit.component)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(from: components)
    }
}
