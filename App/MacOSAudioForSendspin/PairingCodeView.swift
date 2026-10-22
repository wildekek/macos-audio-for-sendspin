import AppKit
import SwiftUI

/// The code a server such as Music Assistant asks for while it pairs with this Mac: this Mac
/// is the display of the dynamic pairing code (pairing.md). It opens when you start the setup
/// on the server, without taking focus from where you type the code, and says when it's done.
/// The code is on the clipboard as soon as it shows: the digits lift and "Copied" appears, and
/// clicking them copies it again. Like the menu: no window controls, and the same glass.
struct PairingCodeView: View {
    let bridge: BridgeController
    /// Dismisses the window; the pairing goes on (the menu still shows the code).
    let close: () -> Void
    /// The last code shown, kept while the window says how it ended.
    @State private var code = ""
    /// Every copy, so each one shows.
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
                VStack(spacing: 6) {
                    Text(grouped(code))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .tracking(2)
                        // Picked up: a lift, then it settles.
                        .keyframeAnimator(initialValue: 1.0, trigger: copies) { content, scale in
                            content.scaleEffect(scale)
                        } keyframes: { _ in
                            SpringKeyframe(1.08, duration: 0.15, spring: .snappy)
                            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { copyCode() }
                        .help("Click to copy it again")
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))
                        .accessibilityHint("Copies the code")
                        .accessibilityAddTraits(.isButton)
                    // Always laid out, only faded and scaled in, so the window's size (set once,
                    // from this state) fits it.
                    Label {
                        Text("Copied")
                    } icon: {
                        Image(systemName: "doc.on.clipboard.fill")
                            .symbolEffect(.bounce, value: copies)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .opacity(copies > 0 ? 1 : 0)
                    .scaleEffect(copies > 0 ? 1 : 0.6)
                    .animation(.spring(duration: 0.35), value: copies > 0)
                    .accessibilityHidden(copies == 0)
                }
                Text("Paste it in \(bridge.sourceServerName) to pair this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Close", action: close)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            // A new code goes on the clipboard at once; its animation follows when the window
            // has had a moment to appear, so it's seen.
            guard let new, new != code else { return }
            code = new
            copyCode(after: .milliseconds(400))
        }
    }

    /// `123-456`, as the spec presents a six-digit code (Pairing Code Presentation).
    private func grouped(_ code: String) -> String {
        "\(code.prefix(3))-\(code.suffix(3))"
    }

    /// The digits only, which any code field takes; then the lift and "Copied".
    private func copyCode(after delay: Duration = .zero) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        Task {
            try? await Task.sleep(for: delay)
            copies += 1
        }
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
