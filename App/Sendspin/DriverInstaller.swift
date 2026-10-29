import Foundation
import Security

/// Installs the audio driver the app carries (Contents/Library/Audio/Plug-Ins/HAL) into
/// /Library/Audio/Plug-Ins/HAL, and tells whether the installed one is this app's version.
enum DriverInstaller {
    enum State: Equatable {
        case notInstalled
        /// Installed, but not the version this app carries.
        case outdated
        case current
    }

    static let installedPath = "/Library/Audio/Plug-Ins/HAL/Sendspin.driver"

    static var bundledURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/Audio/Plug-Ins/HAL/Sendspin.driver")
    }

    static var state: State {
        guard let installed = version(at: URL(fileURLWithPath: installedPath)) else { return .notInstalled }
        guard let bundled = version(at: bundledURL) else { return .current }
        return installed == bundled ? .current : .outdated
    }

    /// Read from the plist each time: `Bundle` caches by path and would miss an update.
    private static func version(at driver: URL) -> String? {
        let plist = NSDictionary(contentsOf: driver.appending(path: "Contents/Info.plist"))
        return plist?["CFBundleVersion"] as? String
    }

    /// Install or update the driver. Returns false when the user cancels the prompt.
    static func install() async throws -> Bool {
        let staging = "\"$staging/Sendspin.driver\""
        // The app bundle is writable by the user, so check the copy root is about to
        // install, not the original: a swap between check and copy can't slip through.
        let commands = [
            "staging=$(mktemp -d /private/tmp/sendspin-driver.XXXXXX)",
            // Also when a step fails, e.g. the signature check.
            "trap 'rm -rf \"$staging\"' EXIT",
            "ditto \(AdminScript.quoted(bundledURL.path)) \(staging)",
            "codesign --verify --strict \(requirement.map { "-R=\(AdminScript.quoted($0)) " } ?? "")\(staging)",
            "mkdir -p /Library/Audio/Plug-Ins/HAL",
            "rm -rf \(AdminScript.quoted(installedPath))",
            "mv \(staging) /Library/Audio/Plug-Ins/HAL/",
            "chown -R root:wheel \(AdminScript.quoted(installedPath))",
            AdminScript.restartCoreAudio,
        ]
        return try await AdminScript.run(
            commands, prompt: "Sendspin wants to install its audio driver.")
    }

    /// The driver must come from this app's developer team. An ad-hoc signed dev build
    /// has no team, so there only the signature's integrity is checked.
    private static var requirement: String? {
        teamIdentifier.map { #"anchor apple generic and certificate leaf[subject.OU] = "\#($0)""# }
    }

    private static var teamIdentifier: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
