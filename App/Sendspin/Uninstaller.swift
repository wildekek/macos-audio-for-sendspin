import Foundation

/// Removes the Sendspin driver and this app with administrator rights. Restarting
/// coreaudiod unloads the driver, so the Mac doesn't need a restart.
enum Uninstaller {
    static let releaseBundleID = "com.sendspin-audio.mac"

    /// Returns false when the user cancels the administrator prompt.
    static func run() async throws -> Bool {
        // The login item goes too. Before the prompt, while the app still exists; put back
        // if the user cancels or the removal fails.
        let wasLoginItem = LoginItem.isEnabled
        try? LoginItem.set(false)
        var removed = false
        defer { if wasLoginItem && !removed { try? LoginItem.set(true) } }
        // Forget its privacy permissions, such as the microphone access older versions
        // asked for (privacy settings are per user, so as the user). This has to happen while
        // the app still exists: tccutil looks the bundle ID up.
        let bundleID = Bundle.main.bundleIdentifier ?? releaseBundleID
        var commands = [
            "{ launchctl asuser \(getuid()) sudo -u \(AdminScript.quoted(NSUserName())) tccutil reset All \(AdminScript.quoted(bundleID)) >/dev/null 2>&1 || true; }",
            "rm -rf \(AdminScript.quoted(DriverInstaller.installedPath))",
        ]
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            commands.append("rm -rf \(AdminScript.quoted(app.path))")
        }
        commands.append(AdminScript.restartCoreAudio)
        removed = try await AdminScript.run(
            commands, prompt: "Sendspin wants to remove its audio driver and the app.")
        return removed
    }
}
