#if os(iOS)
import Foundation
import Testing
@testable import QuillSocialUI

struct SocialRelativeTimestampTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test(arguments: [(0, "0s"), (59, "59s"), (60, "1m"), (3_599, "59m"),
                      (3_600, "1h"), (86_399, "23h"), (86_400, "1d"),
                      (604_799, "6d"), (604_800, "1w"), (2_419_200, "4w")])
    func elapsedBoundaries(seconds: Int, expected: String) {
        let date = Date(timeIntervalSince1970: 1_767_225_600) // January 1, 2026 UTC.
        let result = SocialRelativeTimestamp(date: date, now: date.addingTimeInterval(Double(seconds)), calendar: calendar)
        #expect(result.text == expected)
    }

    @Test("Calendar months and years respect their actual lengths")
    func calendarBoundaries() throws {
        let date = try #require(calendar.date(from: DateComponents(year: 2024, month: 2, day: 1)))
        for (components, expected) in [(DateComponents(month: 1), "1mo"),
                                       (DateComponents(month: 11), "11mo"),
                                       (DateComponents(year: 1), "1y"),
                                       (DateComponents(year: 3), "3y")] {
            let now = try #require(calendar.date(byAdding: components, to: date))
            #expect(SocialRelativeTimestamp(date: date, now: now, calendar: calendar).text == expected)
        }
    }

    @Test("Future clock skew does not produce negative elapsed times")
    func futureDate() {
        let now = Date()
        #expect(SocialRelativeTimestamp(date: now.addingTimeInterval(30), now: now).text == "0s")
    }
}
#endif
