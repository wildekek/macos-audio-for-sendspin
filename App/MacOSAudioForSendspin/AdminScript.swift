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

    /// Restarting coreaudiod loads or unloads drivers without restarting the Mac.
    static let restartCoreAudio =
        "{ launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod; }"
}
