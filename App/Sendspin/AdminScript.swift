import Foundation

/// Runs a shell script as root, after the standard macOS administrator prompt.
enum AdminScript {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs the commands joined with `&&`. Returns false when the user cancels the prompt.
    static func run(_ commands: [String], prompt: String) async throws -> Bool {
        // The script goes in as an argument, so it needs no AppleScript escaping.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
            "-e", "end run",
            commands.joined(separator: " && "),
            prompt,
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if process.terminationStatus == 0 { return true }

        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if message.contains("(-128)") { return false }  // userCanceledErr
        throw Failure(message: message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func quoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Restarting coreaudiod loads or unloads drivers without restarting the Mac. launchd starts it
    /// again. Since macOS 14.4 `launchctl kickstart -k` refuses it, and Apple says to kill it
    /// (Sonoma 14.4 release notes, Core Audio, 123028502).
    ///
    /// audiomxd goes first. Each coreaudiod restart since AirPlayXPCHelper started makes it
    /// re-register AirPlay.driver twice as often as the last (2^n on the nth, a macOS bug), which
    /// from about the 10th keeps coreaudiod busy for minutes (issue #1). AirPlayXPCHelper can't be
    /// restarted itself, but it quits when audiomxd goes away and comes back with the count reset.
    /// It quits at once and re-registers only a second after an interruption, so the old one is
    /// gone before coreaudiod restarts.
    static let restartCoreAudio = "{ killall -9 audiomxd; sleep 1; killall -9 coreaudiod; }"
}
