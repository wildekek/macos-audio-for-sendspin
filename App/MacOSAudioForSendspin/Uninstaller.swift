import Foundation

/// Removes the Sendspin driver, this app and the installer receipts with administrator
/// rights. Restarting coreaudiod unloads the driver, so the Mac doesn't need a restart.
enum Uninstaller {
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/MacOSAudioForSendspin.driver"
    static let packageIDs = ["eu.vooijs.MacOSAudioForSendspin.pkg.app", "eu.vooijs.MacOSAudioForSendspin.pkg.driver"]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Returns false when the user cancels the administrator prompt.
    static func run() async throws -> Bool {
        // Forget the microphone permission (privacy settings are per user, so as the user).
        // This has to happen while the app still exists: tccutil looks the bundle ID up.
        let bundleID = Bundle.main.bundleIdentifier ?? "eu.vooijs.MacOSAudioForSendspin"
        var commands = [
            "{ launchctl asuser \(getuid()) sudo -u \(shellQuoted(NSUserName())) tccutil reset All \(shellQuoted(bundleID)) >/dev/null 2>&1 || true; }",
            "rm -rf \(shellQuoted(driverPath))",
        ]
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            commands.append("rm -rf \(shellQuoted(app.path))")
        }
        // Not installed from the .pkg (a dev build): there are no receipts to forget.
        commands += packageIDs.map { "{ pkgutil --forget \($0) >/dev/null 2>&1 || true; }" }
        commands.append("{ launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod; }")

        // The script goes in as an argument, so it needs no AppleScript escaping.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
            "-e", "end run",
            commands.joined(separator: " && "),
            "macOS Audio for Sendspin wants to remove its audio driver and the app.",
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

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
