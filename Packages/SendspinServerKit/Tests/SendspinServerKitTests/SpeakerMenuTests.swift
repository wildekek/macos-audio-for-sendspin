import Testing
@testable import SendspinServerKit

/// The menu's rules, one test each, as `docs/menu-states.md` states them.
struct SpeakerMenuTests {
    typealias Output = SpeakerMenu.Output

    static let grouped = SpeakerMenu.Context(groupCount: 2)

    static func row(_ output: Output, _ context: SpeakerMenu.Context = grouped) -> SpeakerMenu.Row {
        SpeakerMenu.row(output, in: context)
    }

    // MARK: The check

    /// The check is the group, as in Apple's AirPlay picker: filled while it plays.
    @Test func aSpeakerThatPlaysHasAFilledCheckThatRemovesIt() {
        let row = Self.row(Output(inGroup: true, plays: true))
        #expect(row.check == .filled)
        #expect(row.click == .remove)
        #expect(row.status == nil)
        #expect(!row.showsWarning)
    }

    /// An empty ring invites: that grouping is possible is what Sendspin adds over AirPlay.
    @Test func aSpeakerOutOfTheGroupHasAnEmptyCheckThatAddsIt() {
        let row = Self.row(Output(inGroup: false, plays: false))
        #expect(row.check == .empty)
        #expect(row.click == .add)
        #expect(row.status == nil)
    }

    /// The spinner says it connects; text beside it would say it twice (one indicator per row).
    @Test func aConnectingSpeakerHasASpinnerAndNoConnectingText() {
        let row = Self.row(Output(inGroup: true, plays: false, connection: .connecting))
        #expect(row.check == .spinner)
        #expect(row.click == .remove)
        #expect(row.status == nil)
    }

    /// Grey keeps it clearly chosen while it does nothing; it plays again, blue, once it's back.
    /// The warning gives it some urgency, by the reason, as the Wi-Fi menu marks a network
    /// without internet: the check keeps one meaning.
    @Test func anUnavailableSpeakerInTheGroupHasAGreyCheckAndAWarning() {
        for output in [Output(inGroup: true, plays: false, connection: .unavailable),
                       Output(inGroup: true, plays: false, isDiscovered: false, connection: nil)] {
            let row = Self.row(output)
            #expect(row.check == .grey)
            #expect(row.showsWarning)
            #expect(row.status == "Unavailable")
            #expect(row.click == .remove)
        }
    }

    /// Everything that keeps a chosen speaker from playing is a problem to show.
    @Test(arguments: [
        (PlayerStatus.Connection.disconnected(reason: "user_request"), "Disconnected"),
        (.failed("refused"), "Can't connect"),
        (.pairingRequired, "Needs pairing"),
        (.notApproved, "Identity changed"),
    ])
    func whatIsWrongWithASpeakerInTheGroupGetsAWarning(connection: PlayerStatus.Connection, status: String) {
        let row = Self.row(Output(inGroup: true, plays: false, connection: connection))
        #expect(row.check == .grey)
        #expect(row.showsWarning)
        #expect(row.status == status)
    }

    /// Another server's choice, not a fault: grey, but no warning.
    @Test func aSpeakerAnotherServerTookIsGreyWithoutAWarning() {
        let row = Self.row(Output(inGroup: true, plays: false, connection: .taken))
        #expect(row.check == .grey)
        #expect(!row.showsWarning)
        #expect(row.status == "In use elsewhere")
    }

    /// It left for something else, so it's out of the group; the spec doesn't let the app take
    /// it back by itself, so the status says why, and adding it takes it back.
    @Test func aSpeakerThatLeftForSomethingElseIsOutOfTheGroupAndSaysSo() {
        let row = Self.row(Output(inGroup: false, plays: false, connection: .left))
        #expect(row.check == .empty)
        #expect(row.status == "In use elsewhere")
        #expect(!row.showsWarning)
    }

    /// A row only says why it can't play what you chose.
    @Test func aSpeakerOutOfTheGroupSaysNothingAboutItsConnection() {
        for connection: PlayerStatus.Connection in [.connecting, .unavailable, .failed("x"), .notApproved] {
            #expect(Self.row(Output(inGroup: false, plays: false, connection: connection)).status == nil)
        }
    }

    // MARK: The Mac's own output

    /// There's nowhere else for the sound to go.
    @Test func theMacsOwnOutputAloneCantBeRemoved() {
        let row = Self.row(Output(isLocal: true, inGroup: true, plays: true), SpeakerMenu.Context(groupCount: 1))
        #expect(row.check == .filled)
        #expect(row.click == nil)
    }

    @Test func theMacsOwnOutputWithSpeakersCanBeRemoved() {
        #expect(Self.row(Output(isLocal: true, inGroup: true, plays: true)).click == .remove)
    }

    /// The Mac's own output is always there to take over, so a speaker can always go.
    @Test func aSendspinSpeakerAloneCanBeRemoved() {
        let row = Self.row(Output(inGroup: true, plays: true), SpeakerMenu.Context(groupCount: 1))
        #expect(row.click == .remove)
    }

    // MARK: Groupable

    /// Without a check, the icon says it plays, as in the Sound menu (one indicator per row).
    @Test func anOutputThatIsntGroupableHasNoCheckAndABlueIconWhileItPlays() {
        let playing = Self.row(Output(isLocal: true, isGroupable: false, inGroup: true, plays: true),
                               SpeakerMenu.Context(playsGroupable: false, groupCount: 1))
        #expect(playing.check == .none)
        #expect(playing.click == nil)
        #expect(playing.iconIsBlue)
    }

    /// The check says it; a blue icon too would say it twice.
    @Test func aGroupableOutputsIconNeverTurnsBlue() {
        #expect(!Self.row(Output(inGroup: true, plays: true)).iconIsBlue)
        #expect(!Self.row(Output(isLocal: true, inGroup: true, plays: true)).iconIsBlue)
    }

    /// A check would promise grouping that can't happen: a server plays where it chooses,
    /// and macOS removes an AirPlay output once Sendspin is the Mac's output. The names still
    /// play there.
    @Test func whileWhatPlaysIsntGroupableNothingCanJoin() {
        let context = SpeakerMenu.Context(playsGroupable: false, groupCount: 0)
        let row = Self.row(Output(inGroup: false, plays: false), context)
        #expect(row.check == .none)
        #expect(row.click == nil)
    }

    @Test func withoutACheckConnectingIsSaidInWords() {
        let context = SpeakerMenu.Context(playsGroupable: false, groupCount: 1)
        #expect(Self.row(Output(inGroup: true, plays: false, connection: .connecting), context).status == "Connecting…")
    }

    // MARK: Servers

    @Test func aServerFollowsTheSameRulesAsASpeaker() {
        let context = SpeakerMenu.Context(groupCount: 0)
        let playing = Self.row(SpeakerMenu.server(chosen: true, connected: true), context)
        #expect(playing.check == .none)
        #expect(playing.iconIsBlue)
        #expect(playing.status == nil)

        let goneWhileChosen = Self.row(SpeakerMenu.server(chosen: true, connected: false), context)
        #expect(!goneWhileChosen.iconIsBlue)
        #expect(goneWhileChosen.status == "Unavailable")
        #expect(goneWhileChosen.showsWarning)

        let goneAndNotChosen = Self.row(SpeakerMenu.server(chosen: false, connected: false), context)
        #expect(goneAndNotChosen.status == "Unavailable")
        #expect(goneAndNotChosen.showsWarning)

        let idle = Self.row(SpeakerMenu.server(chosen: false, connected: true), context)
        #expect(!idle.iconIsBlue)
        #expect(idle.status == nil)
    }

    /// One look for one state: a gone server is a problem even when it isn't chosen, as it's
    /// only listed because it's paired.
    @Test func unavailableAlwaysShowsTheWarning() {
        for output in [SpeakerMenu.server(chosen: false, connected: false),
                       SpeakerMenu.server(chosen: true, connected: false),
                       Output(inGroup: true, plays: false, connection: .unavailable),
                       Output(inGroup: false, plays: false, isDiscovered: false, connection: nil)] {
            let row = Self.row(output)
            #expect(row.status == "Unavailable")
            #expect(row.showsWarning)
        }
    }

    @Test func anUnavailableServerAndSpeakerLookTheSame() {
        let server = Self.row(SpeakerMenu.server(chosen: true, connected: false), Self.grouped)
        let speaker = Self.row(Output(isGroupable: false, inGroup: true, plays: false, isDiscovered: false,
                                      connection: nil), Self.grouped)
        #expect(server == speaker)
    }

    // MARK: Choices

    static let mac = "mac"

    /// The Mac plays directly, alone; AUX-2 and Office (unavailable) are found.
    static let direct = SpeakerMenu.State(local: mac, group: [mac], canPlay: [mac, "aux", "pe"])

    /// The Mac and the AUX-2 play together; Office is in the group, unavailable.
    static let grouped3 = SpeakerMenu.State(local: mac, group: [mac, "aux", "office"], canPlay: [mac, "aux", "pe"])

    static func plan(_ action: SpeakerMenu.Action, _ state: SpeakerMenu.State) -> SpeakerMenu.Plan? {
        SpeakerMenu.plan(action, in: state)
    }

    /// Adding starts from what plays now: the Mac plays along, in sync.
    @Test func addingASpeakerToTheMacPlaysThemTogetherThroughSendspin() {
        #expect(Self.plan(.add("aux"), Self.direct) == SpeakerMenu.Plan(group: [Self.mac, "aux"], route: .speakers))
    }

    /// AirPlay can't play along: macOS removes the device once Sendspin is the output.
    @Test func addingASpeakerWhileAirPlayPlaysReplacesIt() {
        var airPlay = Self.direct
        airPlay.localIsGroupable = false
        #expect(Self.plan(.add("aux"), airPlay) == SpeakerMenu.Plan(group: ["aux"], route: .speakers))
    }

    @Test func addingTheMacJoinsTheSpeakers() {
        let speakerAlone = SpeakerMenu.State(local: Self.mac, group: ["aux"], canPlay: [Self.mac, "aux"])
        #expect(Self.plan(.add(Self.mac), speakerAlone) == SpeakerMenu.Plan(group: [Self.mac, "aux"], route: .speakers))
    }

    @Test func addingAnAirPlayOutputPlaysItAlone() {
        let state = SpeakerMenu.State(local: Self.mac, localIsGroupable: false, group: ["aux"], canPlay: [Self.mac, "aux"])
        #expect(Self.plan(.add(Self.mac), state) == SpeakerMenu.Plan(group: [Self.mac], route: .direct))
    }

    /// Alone, the Mac's own output plays directly: nothing to keep in sync with, no delay.
    @Test func removingTheLastSendspinSpeakerHandsOverToTheMac() {
        let speakerAlone = SpeakerMenu.State(local: Self.mac, group: ["aux"], canPlay: [Self.mac, "aux"])
        #expect(Self.plan(.remove("aux"), speakerAlone) == SpeakerMenu.Plan(group: [Self.mac], route: .direct))
        let withTheMac = SpeakerMenu.State(local: Self.mac, group: [Self.mac, "aux"], canPlay: [Self.mac, "aux"])
        #expect(Self.plan(.remove("aux"), withTheMac) == SpeakerMenu.Plan(group: [Self.mac], route: .direct))
    }

    /// Something always plays after a choice; the speakers that can't stay in the group and
    /// join in once they're back.
    @Test func whenNothingLeftCanPlayTheMacJoinsAndTheOthersWait() {
        let state = SpeakerMenu.State(local: Self.mac, group: ["aux", "office"], canPlay: [Self.mac, "aux"])
        #expect(Self.plan(.remove("aux"), state) == SpeakerMenu.Plan(group: [Self.mac, "office"], route: .speakers))
    }

    @Test func removingASpeakerKeepsTheRestOfTheGroup() {
        #expect(Self.plan(.remove("aux"), Self.grouped3) == SpeakerMenu.Plan(group: [Self.mac, "office"], route: .speakers))
    }

    @Test func theMacAloneCantBeRemoved() {
        #expect(Self.plan(.remove(Self.mac), Self.direct) == nil)
    }

    @Test func theMacCantLeaveOnlyUnavailableSpeakersBehind() {
        let state = SpeakerMenu.State(local: Self.mac, group: [Self.mac, "office"], canPlay: [Self.mac])
        #expect(Self.plan(.remove(Self.mac), state) == SpeakerMenu.Plan(group: [Self.mac, "office"], route: .speakers))
    }

    @Test func removingWhatIsntInTheGroupChangesNothing() {
        #expect(Self.plan(.remove("pe"), Self.grouped3) == nil)
    }

    @Test func clickingTheMacsNamePlaysItDirectlyAlone() {
        #expect(Self.plan(.playOnly(Self.mac), Self.grouped3) == SpeakerMenu.Plan(group: [Self.mac], route: .direct))
    }

    /// As in the Sound menu: the name chooses one output; the check groups.
    @Test func clickingASpeakersNamePlaysThereOnly() {
        #expect(Self.plan(.playOnly("aux"), Self.grouped3) == SpeakerMenu.Plan(group: ["aux"], route: .speakers))
    }

    @Test func clickingAnUnavailableSpeakersNameBringsTheMacAlong() {
        #expect(Self.plan(.playOnly("office"), Self.grouped3) == SpeakerMenu.Plan(group: [Self.mac, "office"], route: .speakers))
    }

    /// A server can't be grouped with; speakers that stayed in a group nobody plays to
    /// would be stale. Unavailable ones leave the list with it (what you didn't choose, leaves).
    @Test func choosingAServerDissolvesTheGroupUnavailableSpeakersToo() {
        #expect(Self.plan(.chooseServer, Self.grouped3) == SpeakerMenu.Plan(group: [], route: .server))
    }

    @Test func aSpeakerChosenAfterAServerStartsANewGroup() {
        let server = SpeakerMenu.State(local: Self.mac, group: [], canPlay: [Self.mac, "aux"])
        #expect(Self.plan(.add("aux"), server) == SpeakerMenu.Plan(group: ["aux"], route: .speakers))
    }
}
