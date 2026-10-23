import AppKit
import SendspinServerKit
import SwiftUI

/// An output's icon: an SF Symbol, or a template image (Music Assistant's own mark, from the
/// app's asset catalog, or loaded from its file), drawn the same way.
public enum OutputGlyph {
    case symbol(String)
    case asset(String)
    case image(NSImage)

    @ViewBuilder var image: some View {
        switch self {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        case .image(let image):
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        }
    }
}

/// A row in the menu, for a speaker, the Mac's own output or a server alike: its round icon,
/// its name, the volume slider while it plays or its status, then its check. How it shows its
/// state is `SpeakerMenu.Row`; this only draws it, and says what was clicked.
public struct OutputRow: View {
    let name: String
    let glyph: OutputGlyph
    let row: SpeakerMenu.Row
    let volume: Binding<Double>?
    let format: String?
    let statusHelp: String
    let onName: () -> Void
    let onCheck: () -> Void
    @State private var hovering = false

    /// - Parameters:
    ///   - volume: the slider, while it plays and its volume can be set.
    ///   - format: what it receives (e.g. "FLAC · 48 kHz · 16-bit"), shown over the name while
    ///     hovering it.
    ///   - onName: clicking the icon or name, or the status beside it: play there only.
    ///   - onCheck: clicking the check (`row.click` says what it does).
    public init(name: String, glyph: OutputGlyph, row: SpeakerMenu.Row, volume: Binding<Double>? = nil,
                format: String? = nil, statusHelp: String = "", onName: @escaping () -> Void = {},
                onCheck: @escaping () -> Void = {}) {
        self.name = name
        self.glyph = glyph
        self.row = row
        self.volume = volume
        self.format = format
        self.statusHelp = statusHelp
        self.onName = onName
        self.onCheck = onCheck
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button(action: onName) {
                HStack(spacing: 10) {
                    OutputIcon(glyph: glyph, isBlue: row.iconIsBlue)
                    // While hovering the name, the format it receives takes its place. It's drawn
                    // over the name, so nothing moves: the row has no room for both.
                    let shownFormat = hovering ? format : nil
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(shownFormat == nil ? 1 : 0)
                        .overlay(alignment: .leading) {
                            if let shownFormat {
                                Text(shownFormat)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .onHover { hovering = $0 }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play on \(name) only")

            if let volume {
                Slider(value: volume, in: 0...100)
                    .controlSize(.small)
                    // Neutral like Apple Music's AirPlay sliders, not the accent colour.
                    .tint(.primary.opacity(0.8))
                    .frame(width: 80)
                    .accessibilityLabel("\(name) volume")
            } else if let status = row.status {
                StatusLabel(text: status, showsWarning: row.showsWarning, help: statusHelp)
                    // "Identity changed" is what asks for the click, so the status takes one too.
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onName)
            }

            if row.check != .none {
                Button(action: onCheck) {
                    CheckMark(check: row.check)
                        // The row's full height and some room before it: easy to hit.
                        .frame(width: 30, height: 38, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(checkLabel)
                .accessibilityLabel(checkLabel)
                .accessibilityAddTraits(row.check == .empty ? [] : .isSelected)
            }
        }
        .frame(height: 38)
    }

    private var checkLabel: String {
        switch (row.check, row.click) {
        case (.spinner, _): "Connecting to \(name); click to remove it"
        case (.empty, _): "Add \(name)"
        case (_, .remove): "Remove \(name)"
        default: "\(name) plays"
        }
    }
}

/// An output's round icon: blue while it plays where there's no check to say it
/// (`SpeakerMenu.Row.iconIsBlue`), as in the Sound menu.
struct OutputIcon: View {
    let glyph: OutputGlyph
    let isBlue: Bool

    var body: some View {
        glyph.image
            .foregroundStyle(isBlue ? Color.white : Color.primary)
            .frame(width: 26, height: 26)
            .background(isBlue ? Color.accentColor : Color.secondary.opacity(0.2), in: Circle())
    }
}

/// Why an output can't play, on the right of its row: with a warning triangle when something
/// is wrong (`SpeakerMenu.Row.showsWarning`), as the Wi-Fi menu marks a network without internet.
struct StatusLabel: View {
    let text: String
    let showsWarning: Bool
    var help = ""

    var body: some View {
        HStack(spacing: 4) {
            if showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.warningOrange)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(showsWarning ? "Warning: \(text)" : text)
    }
}

/// The round check, as in Apple's AirPlay picker: filled while it plays, grey while it's in the
/// group but can't play, a spinner while it connects, an empty ring when it's out of the group.
struct CheckMark: View {
    let check: SpeakerMenu.Row.Check

    var body: some View {
        ZStack {
            switch check {
            case .spinner:
                ProgressView()
                    .controlSize(.small)
            case .filled, .grey:
                Circle().fill(check == .grey ? Color.secondary.opacity(0.5) : Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            case .empty, .none:
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
    }
}

extension Color {
    /// A darker orange than the system's in light mode, so the warning stands out on the light
    /// menu; the system's own in dark mode.
    static let warningOrange = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)
            : NSColor(srgbRed: 0.76, green: 0.37, blue: 0, alpha: 1)
    })
}
