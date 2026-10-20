import AppKit

/// Release builds belong in Applications. Opened from the disk image or Downloads, macOS
/// runs a read-only copy of the app (App Translocation), gone once the disk image is ejected.
enum AppLocation {
    static var needsMove: Bool {
        #if DEBUG
        return false  // dev builds run from the build folder
        #else
        let path = Bundle.main.bundlePath
        return !path.hasPrefix("/Applications/") && !path.hasPrefix(NSHomeDirectory() + "/Applications/")
        #endif
    }

    /// Copy the app to /Applications, off the main thread; an older copy goes to the Trash.
    static func copyToApplications() async throws -> URL {
        let source = Bundle.main.bundleURL
        return try await Task.detached {
            let destination = URL(fileURLWithPath: "/Applications").appending(path: source.lastPathComponent)
            let files = FileManager.default
            if files.fileExists(atPath: destination.path) {
                try files.trashItem(at: destination, resultingItemURL: nil)
            }
            try files.copyItem(at: source, to: destination)
            // The user already chose to open this app; the copy shouldn't ask again.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
            if (try? xattr.run()) != nil { xattr.waitUntilExit() }
            return destination
        }.value
    }

    /// Open the copy, then quit this one. The copy's first launch takes a few seconds:
    /// macOS checks the whole app before it runs.
    @MainActor static func relaunch(at app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        NSApp.terminate(nil)
    }
}
