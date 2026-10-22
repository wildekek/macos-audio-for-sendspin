import AppKit
import SwiftUI

@main
struct MacOSAudioForSendspinApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(bridge: appDelegate.bridge)
        } label: {
            // Filled while the Mac's sound is playing; both are templates, in the menu bar's colour.
            Image(appDelegate.bridge.isPlaying ? "MenuBarIconPlaying" : "MenuBarIcon")
                .accessibilityLabel(appDelegate.bridge.isPlaying ? "Sendspin, playing" : "Sendspin")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(bridge: appDelegate.bridge)
        }
    }
}

/// Owns the bridge, and opens the welcome window on first launch: a menu bar app has no
/// view on screen yet that could open it from SwiftUI.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let bridge = BridgeController()
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !bridge.isWelcomeDone || AppLocation.needsMove { showWelcome() }
    }

    private func showWelcome() {
        let view = WelcomeView(bridge: bridge,
                               done: { [weak self] in self?.welcomeWindow?.close() },
                               refocus: { [weak self] in self?.bringWelcomeToFront() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = "macOS Audio for Sendspin"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        welcomeWindow = window
        // A menu bar app never becomes the active app, so after a system prompt (password,
        // microphone) macOS hands focus back to whatever was active before. While the welcome
        // window is open the app is a regular one, with a Dock icon, and keeps its focus.
        NSApp.setActivationPolicy(.regular)
        bringWelcomeToFront()
    }

    private func bringWelcomeToFront() {
        guard let welcomeWindow else { return }
        NSApp.activate()
        welcomeWindow.makeKeyAndOrderFront(nil)
    }

    /// Done or closed early: either way, start what the window didn't get to.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === welcomeWindow else { return }
        welcomeWindow = nil
        NSApp.setActivationPolicy(.accessory)  // back to a menu bar app
        Task { await bridge.finishWelcome() }
    }
}
