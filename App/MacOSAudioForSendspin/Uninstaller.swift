import Foundation

/// Removes the Sendspin driver and this app with administrator rights. Restarting
/// coreaudiod unloads the driver, so the Mac doesn't need a restart.
enum Uninstaller {
    static let releaseBundleID = "eu.vooijs.MacOSAudioForSendspin"

    /// Returns false when the user cancels the administrator prompt.
    static func run() async throws -> Bool {
        // The login item goes too. Before the prompt, while the app still exists; put back
        // if the user cancels or the removal fails.
        let wasLoginItem = LoginItem.isEnabled
        try? LoginItem.set(false)
        var removed = false
        defer { if wasLoginItem && !removed { try? LoginItem.set(true) } }
        // Forget the microphone permission (privacy settings are per user, so as the user).
        // This has to happen while the app still exists: tccutil looks the bundle ID up.
        let bundleID = Bundle.main.bundleIdentifier ?? releaseBundleID
        var commands = [
            "{ launchctl asuser \(getuid()) sudo -u \(AdminScript.quoted(NSUserName())) tccutil reset All \(AdminScript.quoted(bundleID)) >/dev/null 2>&1 || true; }",
            "rm -rf \(AdminScript.quoted(DriverInstaller.installedPath))",
        ]
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            commands.append("rm -rf \(AdminScript.quoted(app.path))")
        }
        // Receipts of the earlier .pkg installer, if this Mac had one. The app's only when
        // this is the release: a dev build uninstalling itself leaves a release alone.
        var packageIDs = ["\(releaseBundleID).pkg.driver"]
        if bundleID == releaseBundleID { packageIDs.append("\(releaseBundleID).pkg.app") }
        commands += packageIDs.map { "{ pkgutil --forget \($0) >/dev/null 2>&1 || true; }" }
        commands.append(AdminScript.restartCoreAudio)
        removed = try await AdminScript.run(
            commands, prompt: "macOS Audio for Sendspin wants to remove its audio driver and the app.")
        return removed
    }
}
