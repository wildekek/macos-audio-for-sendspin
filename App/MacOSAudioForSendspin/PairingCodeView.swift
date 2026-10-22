import AppKit
import SwiftUI

/// The code a server such as Music Assistant asks for while it pairs with this Mac: this Mac
/// is the display of the dynamic pairing code (pairing.md). It opens when you start the setup
/// on the server, without taking focus from where you type the code, and says when it's done.
/// Like the menu: no window controls, and the same glass.
struct PairingCodeView: View {
    let bridge: BridgeController
    /// The last code shown, kept while the window says how it ended.
    @State private var code = ""
    @State private var copied = false
    /// Every copy, so each click shows.
    @State private var copies = 0

    var body: some View {
        let status = bridge.sourceStatus
        VStack(spacing: 14) {
            Group {
                if bridge.sourceServerIsMusicAssistant {
                    Image("MusicAssistantIcon").resizable().scaledToFit()
                } else {
                    Image(systemName: "server.rack").resizable().scaledToFit()
                }
            }
            .frame(width: 30, height: 30)
            .foregroundStyle(.secondary)
            if status.pairingCode != nil {
                Text(grouped(code))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(2)
                    .textSelection(.enabled)
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
                Text("Enter this code in \(bridge.sourceServerName) to pair this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Pill(text: copied ? "Copied" : "Copy Code", checked: copied, presses: copies)
                        .onTapGesture(perform: copyCode)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Copies the code")
                    Button("Cancel") { bridge.cancelPairing() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if status.paired {
                Label("Paired with \(bridge.sourceServerName)", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .symbolRenderingMode(.multicolor)
            } else {
                Text("Pairing ended")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 300)
        .modifier(GlassBackground(cornerRadius: 22))
        .onChange(of: status.pairingCode, initial: true) { _, new in
            if let new { code = new }
        }
    }

    /// `123-456`, as the spec presents a six-digit code (Pairing Code Presentation).
    private func grouped(_ code: String) -> String {
        "\(code.prefix(3))-\(code.suffix(3))"
    }

    /// The digits only: what any code field takes.
    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        copies += 1
    }
}

/// The menu's look: Liquid Glass on macOS 26, the system material before it.
private struct GlassBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// A borderless panel that still takes clicks: borderless windows can't become key by
/// themselves. It only does when clicked, so showing it leaves the keyboard where it was.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
