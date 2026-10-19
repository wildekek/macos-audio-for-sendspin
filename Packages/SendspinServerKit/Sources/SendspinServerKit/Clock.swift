import Darwin

/// The server clock: host time (`mach_absolute_time`) in microseconds.
///
/// CoreAudio stamps captured buffers with the same host time, so a capture
/// timestamp converts directly onto the timeline the players synchronize to.
public enum ServerClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func nowMicros() -> Int64 {
        micros(fromHostTime: mach_absolute_time())
    }

    public static func micros(fromHostTime hostTime: UInt64) -> Int64 {
        let nanos = hostTime.multipliedFullWidth(by: UInt64(timebase.numer))
        let (quotient, _) = UInt64(timebase.denom).dividingFullWidth(nanos)
        return Int64(quotient / 1_000)
    }
}
