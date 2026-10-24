import AppKit
import SendspinMenuUI
import SendspinServerKit
import SwiftUI
import Testing

/// Every state of a row, as the menu draws it: the state from the rules (`SpeakerMenu`), the row
/// from the view the app uses (`OutputRow`), and a sheet of them all with what each means.
@Suite("Row snapshots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                "Rendering differs between macOS versions: recorded and compared on a Mac"),
       // Text is drawn at the scale of the screen the window is on; on a 1x screen it's scaled up, soft.
       .enabled("Recorded on a Retina screen: the main screen must be 2x") {
           await MainActor.run { NSScreen.main?.backingScaleFactor == 2 }
       })
@MainActor
struct RowSnapshotTests {
    struct State: CustomTestStringConvertible, Sendable {
        var id: String
        var title: String
        var means: String
        var name: String
        var output: SpeakerMenu.Output
        var context = SpeakerMenu.Context(groupCount: 2)
        var glyph = "hifispeaker.fill"
        var plays = false
        var server = false

        var testDescription: String { title }
        var row: SpeakerMenu.Row { SpeakerMenu.row(output, in: context) }
    }

    nonisolated static let states: [State] = [
        State(id: "plays", title: "Plays", means: "A filled check, its volume beside it.",
              name: "Home Assistant Connect AUX-2", output: .init(inGroup: true, plays: true), plays: true),
        State(id: "can-join", title: "Can join", means: "An empty check: click it to add. The name plays there only.",
              name: "Home Assistant Voice PE", output: .init(inGroup: false, plays: false)),
        State(id: "joining", title: "Joining", means: "A spinner in place of the check while it connects; clicking it cancels.",
              name: "Home Assistant Voice PE", output: .init(inGroup: true, plays: false, connection: .connecting)),
        State(id: "unavailable", title: "Unavailable", means: "In the group, doing nothing: a grey check, and a warning by the reason.",
              name: "Office", output: .init(inGroup: true, plays: false, connection: .unavailable)),
        State(id: "in-use-elsewhere", title: "In use elsewhere", means: "Unchecked; checking it takes it back.",
              name: "Home Assistant Voice PE", output: .init(inGroup: false, plays: false, connection: .left)),
        State(id: "mac-alone", title: "Mac, alone", means: "Played directly. Its check stays: it's all that plays.",
              name: "MacBook Pro Speakers", output: .init(isLocal: true, inGroup: true, plays: true),
              context: .init(groupCount: 1), glyph: "laptopcomputer", plays: true),
        State(id: "airplay", title: "AirPlay", means: "Not groupable: no check, blue while it plays.",
              name: "Living Room", output: .init(isLocal: true, isGroupable: false, inGroup: true, plays: true),
              context: .init(playsGroupable: false, groupCount: 1), glyph: "homepod.fill", plays: true),
        State(id: "nothing-can-join", title: "While AirPlay or a server plays",
              means: "What plays isn't groupable: no checks. The name plays there.",
              name: "Home Assistant Connect AUX-2", output: .init(inGroup: false, plays: false),
              context: .init(playsGroupable: false, groupCount: 1)),
        State(id: "server", title: "A server", means: "Not groupable, below the divider; blue while it plays.",
              name: "Music Assistant", output: SpeakerMenu.server(chosen: true, connected: true),
              context: .init(groupCount: 0), server: true),
        State(id: "server-unavailable", title: "A server, unavailable", means: "Unavailable, with the warning, chosen or not.",
              name: "Music Assistant", output: SpeakerMenu.server(chosen: false, connected: false),
              context: .init(groupCount: 0), server: true),
    ]

    /// Music Assistant's mark, from the app's asset catalog.
    static let musicAssistantMark: NSImage? = {
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../App/MacOSAudioForSendspin/Assets.xcassets/MusicAssistantIcon.imageset/music-assistant.svg")
            .standardized
        let image = NSImage(contentsOf: url)
        image?.isTemplate = true
        return image
    }()

    static func row(_ state: State) -> OutputRow {
        let glyph: OutputGlyph = state.server ? (musicAssistantMark.map(OutputGlyph.image) ?? .symbol("server.rack"))
            : .symbol(state.glyph)
        return OutputRow(name: state.name, glyph: glyph, row: state.row,
                         volume: state.plays ? .constant(55) : nil)
    }

    @Test("Each row state looks as recorded", arguments: states)
    func eachState(_ state: State) {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let view = Self.row(state)
                .padding(.horizontal, 14)
                .background(Color(nsColor: .windowBackgroundColor))
            Snapshot.assertMatches(Snapshot.render(view, width: 360, appearance: appearance),
                                   named: "row-\(state.id)-\(suffix)")
        }
    }

    @Test("The sheet of every row state looks as recorded")
    func sheet() {
        // The captions, the menu's row width and the sheet's margins.
        let rep = Snapshot.render(RowStatesSheet(states: Self.states, row: Self.row), width: 150 + 16 + 332 + 32 + 48)
        Snapshot.assertMatches(rep, named: "row-states")
    }
}

/// Every state with what it means, on one sheet.
struct RowStatesSheet: View {
    let states: [RowSnapshotTests.State]
    let row: (RowSnapshotTests.State) -> OutputRow

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(state.means)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 150, alignment: .leading)
                    // As wide as in the menu: 360 pt less its padding.
                    row(state)
                        .frame(width: 332)
                }
                .padding(.vertical, 12)
                if index < states.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .padding(24)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
