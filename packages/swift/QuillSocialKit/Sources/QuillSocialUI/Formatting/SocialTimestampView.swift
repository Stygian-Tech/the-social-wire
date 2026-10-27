import SwiftUI

struct SocialTimestampView: View {
    let date: Date

    var body: some View {
        TimelineView(RefreshSchedule(date: date)) { context in
            let timestamp = SocialRelativeTimestamp(date: date, now: context.date)
            Text(timestamp.text)
                .accessibilityLabel(timestamp.accessibilityText)
        }
    }

    /// Only fresh posts tick every second; older timestamps update on minute boundaries.
    private struct RefreshSchedule: TimelineSchedule {
        let date: Date

        func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
            AnySequence {
                var nextDate = startDate
                return AnyIterator {
                    let current = nextDate
                    let age = max(0, current.timeIntervalSince(date))
                    let interval = age < 60 ? 1.0 : 60.0
                    nextDate = current.addingTimeInterval(max(1, interval - age.truncatingRemainder(dividingBy: interval)))
                    return current
                }
            }
        }
    }
}
