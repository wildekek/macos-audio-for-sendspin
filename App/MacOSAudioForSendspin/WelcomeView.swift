import AppKit
import SendspinServerKit
import SwiftUI

/// First launch: the three things the app needs, each explained where it's asked for.
struct WelcomeView: View {
    @Bindable var bridge: BridgeController
    let done: () -> Void
    /// Back to the front after a system prompt, which hands focus to the previous app.
    let refocus: () -> Void
    @State private var needsMove = AppLocation.needsMove
    @State private var moveProgress: String?
    @State private var errorText: String?
    // On by default for the app; a dev build shouldn't become a login item by accident.
    #if DEBUG
    @State private var openAtLogin = false
    #else
    @State private var openAtLogin = true
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to macOS Audio for Sendspin").font(.title2.bold())
                Text("Play your Mac's sound on Sendspin speakers, in sync.")
                    .foregroundStyle(.secondary)
            }

            if needsMove {
                Step(number: 1, title: "Move to Applications",
                     detail: "The app runs from the Applications folder. It will open again from there.",
                     state: moveProgress.map { .busy($0) } ?? .action("Move to Applications") { move() })
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Step(number: 1, title: "Audio driver",
                         detail: "Adds Sendspin as a sound output on your Mac. It asks for your password "
                             + "once, and your Mac's sound pauses for a moment.",
                         state: driverStep)
                    Step(number: 2, title: "Microphone",
                         detail: "Lets the app pick up the sound you send to Sendspin. Nothing is recorded.",
                         state: microphoneStep)
                    Step(number: 3, title: "Local network",
                         detail: "Lets the app find the speakers on your network.",
                         state: networkStep)
                }
            }

            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red)
            }

            HStack(alignment: .firstTextBaseline) {
                Label("You'll find the app in the menu bar.", systemImage: "menubar.arrow.up.rectangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Open at login", isOn: $openAtLogin)
                    .toggleStyle(.checkbox)
                    .disabled(needsMove)
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(needsMove)
            }
        }
        .padding(24)
        .frame(width: 480)
        // The local network prompt reports nothing back; discovery finding access allowed means
        // it's answered.
        .onChange(of: bridge.localNetworkAllowed) { _, allowed in if allowed { refocus() } }
    }

    // MARK: Steps

    private var driverStep: Step.State {
        if bridge.isInstallingDriver { return .busy("Installing…") }
        switch bridge.driverState {
        case .current: return bridge.driverNeedsRestart ? .note("Restart your Mac to finish") : .done("Installed")
        case .outdated: return .action("Update…") { installDriver() }
        case .notInstalled: return .action("Install…") { installDriver() }
        }
    }

    private var microphoneStep: Step.State {
        guard bridge.driverState == .current else { return .waiting }
        switch bridge.microphoneAccess {
        case .authorized: return .done("Allowed")
        case .notDetermined:
            return .action("Allow…") {
                Task {
                    await bridge.requestMicrophoneAccess()
                    refocus()
                }
            }
        default:
            return .action("Open Settings…") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }

    private var networkStep: Step.State {
        guard bridge.driverState == .current, bridge.microphoneAccess != .notDetermined else { return .waiting }
        guard bridge.isDiscovering else { return .action("Allow…") { bridge.startDiscovery() } }
        if bridge.localNetworkDenied {
            return .action("Open Settings…") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
            }
        }
        // Only the permission: the menu lists the speakers, so nobody waits here for them.
        return bridge.localNetworkAllowed ? .done("Allowed") : .busy("Waiting for your answer…")
    }

    private func finish() {
        do {
            try LoginItem.set(openAtLogin)
        } catch {
            Log.warning("Couldn't change the login item: \(error)")
        }
        done()
    }

    private func installDriver() {
        errorText = nil
        Task {
            do {
                _ = try await bridge.installDriver()
            } catch {
                errorText = "Couldn't install the driver: \(error.localizedDescription)"
            }
            refocus()
        }
    }

    private func move() {
        errorText = nil
        moveProgress = "Moving…"
        Task {
            do {
                let app = try await AppLocation.copyToApplications()
                moveProgress = "Opening from Applications…"
                try await AppLocation.relaunch(at: app)
            } catch {
                moveProgress = nil
                errorText = "Couldn't move the app: \(error.localizedDescription). "
                    + "Drag it to the Applications folder yourself, then open it from there."
            }
        }
    }
}

private struct Step: View {
    enum State {
        /// Not yet: an earlier step comes first.
        case waiting
        case action(String, () -> Void)
        case busy(String)
        case note(String)
        case done(String)
    }

    let number: Int
    let title: String
    let detail: String
    let state: State

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if case .done = state {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "\(number).circle")
                        .foregroundStyle(isWaiting ? .tertiary : .secondary)
                }
            }
            .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(isWaiting ? 0.5 : 1)

            Spacer(minLength: 12)

            switch state {
            case .waiting:
                EmptyView()
            case .action(let label, let perform):
                Button(label, action: perform)
            case .busy(let text):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.callout).foregroundStyle(.secondary)
                }
            case .note(let text):
                Text(text).font(.callout).foregroundStyle(.secondary)
            case .done(let text):
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var isWaiting: Bool {
        if case .waiting = state { return true }
        return false
    }
}
