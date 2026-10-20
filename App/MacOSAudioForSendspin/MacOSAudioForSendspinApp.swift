import SwiftUI

@main
struct MacOSAudioForSendspinApp: App {
    @State private var bridge = BridgeController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(bridge: bridge)
        } label: {
            Image("MenuBarIcon")
                .accessibilityLabel(bridge.isStreaming ? "Sendspin, streaming" : "Sendspin")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(bridge: bridge)
        }
    }
}
