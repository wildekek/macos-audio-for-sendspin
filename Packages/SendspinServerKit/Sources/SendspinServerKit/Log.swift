import Foundation

/// Minimal leveled logger writing to stderr; hosts can replace `handler`.
public enum Log {
    public enum Level: Int, Comparable, Sendable {
        case debug, info, warning, error

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public nonisolated(unsafe) static var minimumLevel: Level = .info
    public nonisolated(unsafe) static var handler: @Sendable (Level, String) -> Void = { level, message in
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()
            .secondFraction(.fractional(3)))
        FileHandle.standardError.write(Data("\(time) \(level) \(message)\n".utf8))
    }

    public static func debug(_ message: @autoclosure () -> String) { emit(.debug, message) }
    public static func info(_ message: @autoclosure () -> String) { emit(.info, message) }
    public static func warning(_ message: @autoclosure () -> String) { emit(.warning, message) }
    public static func error(_ message: @autoclosure () -> String) { emit(.error, message) }

    private static func emit(_ level: Level, _ message: () -> String) {
        guard level >= minimumLevel else { return }
        handler(level, message())
    }
}
