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
    private var pairingWindow: NSPanel?
    private var pairingWindowClose: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !bridge.isWelcomeDone || AppLocation.needsMove { showWelcome() }
        bridge.onPairingCode = { [weak self] code in self?.pairingCodeChanged(code) }
    }

    // MARK: Pairing code

    /// Music Assistant started pairing by a code shown here: show it, near the top of the
    /// screen, without taking focus from where it's typed. When it ends, the window says how
    /// for a moment, then closes.
    private func pairingCodeChanged(_ code: String?) {
        if code != nil {
            pairingWindowClose?.cancel()
            if pairingWindow == nil { showPairingWindow() }
        } else if pairingWindow != nil {
            pairingWindowClose = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.pairingWindow?.close()
            }
        }
    }

    private func showPairingWindow() {
        // No window controls, and transparent around the view's glass.
        let panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: PairingCodeView(bridge: bridge) { [weak self] in
            self?.pairingWindow?.close()
        })
        // Sized once, from its largest state (the code): SwiftUI resizing this borderless glass
        // panel during an animation loops in Auto Layout until the stack overflows. Smaller
        // states just shrink their glass inside the transparent window.
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.title = "Pair with \(bridge.sourceServerName)"  // for VoiceOver and the window list
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // On the Space you're on, also over a full-screen app.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - 40))
        }
        pairingWindow = panel
        panel.orderFrontRegardless()
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

    /// Done or closed early: either way, start what the window didn't get to. Closing the
    /// pairing code's window only dismisses it: the pairing goes on, its code in the menu.
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === pairingWindow {
            pairingWindow = nil
            pairingWindowClose?.cancel()
            return
        }
        guard (notification.object as? NSWindow) === welcomeWindow else { return }
        welcomeWindow = nil
        NSApp.setActivationPolicy(.accessory)  // back to a menu bar app
        Task { await bridge.finishWelcome() }
    }
}
