import Foundation

enum Format {
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// Days, hours and minutes: "3d 4h 12m".
    static func uptime(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int64(max(0, seconds)))
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow))
    }

    /// "12 minutes ago", "in 3 days". Anything within a minute reads "just now" so it does not tick.
    static func relative(_ date: Date, to now: Date = .now) -> String {
        guard abs(date.timeIntervalSince(now)) >= 60 else { return "just now" }
        return date.formatted(.relative(presentation: .numeric))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Timer digits: "4:05" under an hour, "1:04:05" after.
    static func clock(_ elapsed: TimeInterval) -> String {
        Duration.seconds(Int64(max(0, elapsed)))
            .formatted(.time(pattern: elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    static func hours(_ hours: Int) -> String {
        Duration.seconds(Int64(hours) * 3600)
            .formatted(.units(allowed: [.days, .hours], width: .wide))
    }
}
