import Foundation
import CoreLogic

// When the budgeting month starts. Per device, like the other app preferences; income and
// expense figures are derived from booking dates, so a change recalculates every month.
enum CycleSettings {
    static let startDayKey = "dashboard.cycleStartDay"
    static let startsEarlyOnWeekendsKey = "dashboard.cycleStartsEarlyOnWeekends"
    // Days a single month starts on instead, as comma-separated yyyy-MM-dd so @AppStorage can watch them.
    static let oneOffStartsKey = "dashboard.cycleOneOffStarts"

    static var current: CoreLogic.Dashboard.Cycle {
        let d = UserDefaults.standard
        let day = d.integer(forKey: startDayKey)
        return .init(startDay: day == 0 ? 1 : day,
                     startsEarlyOnWeekends: d.object(forKey: startsEarlyOnWeekendsKey) as? Bool ?? true,
                     oneOffStarts: oneOffStarts(d.string(forKey: oneOffStartsKey) ?? ""))
    }

    static func oneOffStarts(_ stored: String) -> [Date] {
        stored.split(separator: ",").compactMap { day.date(from: String($0)) }.sorted()
    }

    static func storing(_ starts: [Date]) -> String {
        Set(starts.map(day.string)).sorted().joined(separator: ",")
    }

    // The day picked on this phone's calendar, as the UTC day the months are counted in.
    static func utcDay(_ picked: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: Calendar.current.dateComponents([.year, .month, .day], from: picked))!
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
