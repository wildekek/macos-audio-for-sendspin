import AppKit
import SendspinServerKit
import SwiftUI

/// Scanning a speaker's pairing QR code, in a glass panel of its own: the menu would close as
/// soon as macOS asks about the camera, or at any click elsewhere, while this stays. The camera
/// shows mirrored with framing corners, and over the picture what's happening: the instruction,
/// a token being read (blue, at least a moment), paired (green, after which the window closes),
/// or one that didn't match (orange). Cancel closes it; the pairing stays open in the menu.
struct QRScanView: View {
    let bridge: BridgeController
    /// The speaker's instance name.
    let name: String
    let close: () -> Void

    enum Phase: Equatable {
        case looking(again: Bool)
        case pairing
        case paired
    }

    /// The QR code in view, and when it was last seen: one that's held up again after it was
    /// out of view counts as a new scan, so a token can be tried again on purpose.
    @State private var inView: (code: String, at: Date)?
    /// A scan was read just now: "Token read" shows a moment however fast the answer comes.
    @State private var reading = false
    /// What the camera read isn't a pairing token at all.
    @State private var unreadable = false
    /// Bumped when macOS answers the camera question: the window looks again.
    @State private var answers = 0

    private var speaker: String { bridge.displayName(name) }
    private var locations: [PairMethods.Location] { bridge.pairMethods(for: name)?.pairingPSK ?? [] }

    private var phase: Phase {
        if let pairing = bridge.speakerPairing, pairing.name == name, case .token = pairing.method {
            return pairing.progress == .paired ? .paired : .pairing
        }
        if let entry = bridge.tokenEntry, entry.name == name { return .looking(again: entry.again) }
        return .looking(again: false)
    }

    private var wrong: Bool { phase == .looking(again: true) || unreadable }
    /// A read stays "Token read" a moment, even if it failed at once.
    private var shown: Phase { reading && phase != .paired ? .pairing : phase }

    var body: some View {
        let _ = answers
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(Color.secondary.opacity(0.2), in: Circle())
                Text("Scan \(speaker)'s QR code")
                    .font(.headline)
            }
            if QRScanner.isRefused {
                refused
            } else {
                camera
            }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            // Laid out always, so the window keeps its size (set once): gone once paired.
            .opacity(phase == .paired ? 0 : 1)
        }
        .padding(16)
        .frame(width: 424)
        .modifier(GlassBackground(cornerRadius: 18))
    }

    private var refused: some View {
        VStack(spacing: 8) {
            Text("The camera isn't allowed for this app.")
            Button("Allow it in System Settings") {
                NSWorkspace.shared.open(QRScanner.settingsURL)
            }
            .buttonStyle(.link)
            Text("Or paste \(speaker)'s token in the menu.")
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(width: 392, height: 250)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The picture, the framing corners, and over it what's happening.
    private var camera: some View {
        ZStack(alignment: .bottom) {
            QRScanner(onCode: { scanned($0) }, onAnswer: { answers += 1 })
            FramingCorners(color: cornerColor)
                .frame(width: 140, height: 140)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 7) {
                switch shown {
                case .pairing:
                    ProgressView().controlSize(.small).tint(.white)
                case .paired:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .looking:
                    if wrong { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                }
                Text(overlayText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 9))
            .padding(10)
        }
        .frame(width: 392, height: 250)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Camera: \(overlayText)")
    }

    private var cornerColor: Color {
        switch shown {
        case .pairing: .accentColor
        case .paired: .green
        case .looking: wrong ? .orange : .white
        }
    }

    private var overlayText: String {
        switch shown {
        case .pairing: return "Token read. Pairing with \(speaker)…"
        case .paired: return "Paired with \(speaker)"
        case .looking:
            if wrong { return "That token didn't match. Hold up \(speaker)'s own QR code." }
            let onDevice = locations.contains(.device), onLeaflet = locations.contains(.leaflet)
            let place = onDevice && onLeaflet ? "on \(speaker) or its leaflet"
                : onDevice ? "on \(speaker)" : "on the leaflet that came with \(speaker)"
            return "Hold the QR code \(place) up to the camera"
        }
    }

    /// A QR code the camera reads, a few times a second while it's in view. Only a new one
    /// counts: a different code, or the same one held up again.
    private func scanned(_ code: String) {
        let now = Date()
        let isNew = inView.map { $0.code != code || now.timeIntervalSince($0.at) > 1.5 } ?? true
        inView = (code, now)
        guard isNew, case .looking = phase else { return }
        let token = PairingToken.decodePairingPSK(code)
        Log.info("QR code read: " + (token.map { "a pairing token for \($0.clientID)" } ?? "not a pairing token"))
        reading = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            reading = false
        }
        if let token {
            unreadable = false
            bridge.pairWithToken(name, token: token)
        } else {
            unreadable = true
        }
    }
}

/// Four corners that frame where the QR code goes.
private struct FramingCorners: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let arm: CGFloat = 20
            var path = Path()
            for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (size.width, 0, -1, 1), (0, size.height, 1, -1),
                                   (size.width, size.height, -1, -1)] {
                path.move(to: CGPoint(x: x + dx * arm, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + dy * arm))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

