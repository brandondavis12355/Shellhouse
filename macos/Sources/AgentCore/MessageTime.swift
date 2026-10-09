import Foundation

/// The short "when" label shown under every chat message: the time for
/// today, "Yesterday" plus the time, the month and day this year, and the
/// full date before that.
public enum MessageTime {
    public static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day().hour().minute()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    /// The full date and time, for the hover tooltip.
    public static func full(for date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: locale))
    }
}
