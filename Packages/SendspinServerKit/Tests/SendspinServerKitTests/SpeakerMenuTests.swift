import Testing
@testable import SendspinServerKit

// The rules of the speaker menu: one test per rule, named after it, with why it is so. Read as a
// spec (`swift test --list-tests`, or a test report); `docs/menu-states.md` holds the rest of
// the menu.

fileprivate typealias Output = SpeakerMenu.Output

fileprivate let grouped = SpeakerMenu.Context(groupCount: 2)

fileprivate func row(_ output: Output, _ context: SpeakerMenu.Context = grouped) -> SpeakerMenu.Row {
    SpeakerMenu.row(output, in: context)
}

fileprivate let mac = "mac"

/// The Mac plays directly, alone; the AUX-2 and the Voice PE are found.
fileprivate let direct = SpeakerMenu.State(local: mac, group: [mac], canPlay: [mac, "aux", "pe"])

/// The Mac and the AUX-2 play together; Office is in the group, unavailable.
fileprivate let grouped3 = SpeakerMenu.State(local: mac, group: [mac, "aux", "office"], canPlay: [mac, "aux", "pe"])

fileprivate func plan(_ action: SpeakerMenu.Action, _ state: SpeakerMenu.State) -> SpeakerMenu.Plan? {
    SpeakerMenu.plan(action, in: state)
}

@Suite("Speaker menu rules")
struct SpeakerMenuTests {

    @Suite("The check")
    struct TheCheck {
        /// The check is the group, as in Apple's AirPlay picker: filled while it plays.
        @Test("A speaker that plays has a filled check that removes it") func aSpeakerThatPlaysHasAFilledCheckThatRemovesIt() {
            let row = row(Output(inGroup: true, plays: true))
            #expect(row.check == .filled)
            #expect(row.click == .remove)
            #expect(row.status == nil)
            #expect(!row.showsWarning)
        }

        /// An empty ring invites: that grouping is possible is what Sendspin adds over AirPlay.
        @Test("A speaker out of the group has an empty check that adds it") func aSpeakerOutOfTheGroupHasAnEmptyCheckThatAddsIt() {
            let row = row(Output(inGroup: false, plays: false))
            #expect(row.check == .empty)
            #expect(row.click == .add)
            #expect(row.status == nil)
        }

        /// The spinner says it connects; text beside it would say it twice (one indicator per row).
        @Test("A connecting speaker has a spinner, and no \"Connecting…\" text") func aConnectingSpeakerHasASpinnerAndNoConnectingText() {
            let row = row(Output(inGroup: true, plays: false, connection: .connecting))
            #expect(row.check == .spinner)
            #expect(row.click == .remove)
            #expect(row.status == nil)
        }

        /// Grey keeps it clearly chosen while it does nothing; it plays again, blue, once it's back.
        /// The warning gives it some urgency, by the reason, as the Wi-Fi menu marks a network
        /// without internet: the check keeps one meaning.
        @Test("An unavailable speaker in the group has a grey check and a warning") func anUnavailableSpeakerInTheGroupHasAGreyCheckAndAWarning() {
            for output in [Output(inGroup: true, plays: false, connection: .unavailable),
                           Output(inGroup: true, plays: false, isDiscovered: false, connection: nil)] {
                let row = row(output)
                #expect(row.check == .grey)
                #expect(row.showsWarning)
                #expect(row.status == "Unavailable")
                #expect(row.click == .remove)
            }
        }

        /// Everything that keeps a chosen speaker from playing is a problem to show.
        @Test("What's wrong with a speaker in the group gets a warning", arguments: [
            (PlayerStatus.Connection.disconnected(reason: "user_request"), "Disconnected"),
            (.failed("refused"), "Can't connect"),
            (.pairingRequired, "Needs pairing"),
            (.notApproved, "Identity changed"),
        ])
        func whatIsWrongWithASpeakerInTheGroupGetsAWarning(connection: PlayerStatus.Connection, status: String) {
            let row = row(Output(inGroup: true, plays: false, connection: connection))
            #expect(row.check == .grey)
            #expect(row.showsWarning)
            #expect(row.status == status)
        }

        /// Another server's choice, not a fault: grey, but no warning.
        @Test("A speaker another server took is grey, without a warning") func aSpeakerAnotherServerTookIsGreyWithoutAWarning() {
            let row = row(Output(inGroup: true, plays: false, connection: .taken))
            #expect(row.check == .grey)
            #expect(!row.showsWarning)
            #expect(row.status == "In use elsewhere")
        }

        /// It left for something else, so it's out of the group; the spec doesn't let the app take
        /// it back by itself, so the status says why, and adding it takes it back.
        @Test("A speaker that left for something else is out of the group, and says so") func aSpeakerThatLeftForSomethingElseIsOutOfTheGroupAndSaysSo() {
            let row = row(Output(inGroup: false, plays: false, connection: .left))
            #expect(row.check == .empty)
            #expect(row.status == "In use elsewhere")
            #expect(!row.showsWarning)
        }

        /// A row only says why it can't play what you chose.
        @Test("A speaker out of the group says nothing about its connection") func aSpeakerOutOfTheGroupSaysNothingAboutItsConnection() {
            for connection: PlayerStatus.Connection in [.connecting, .unavailable, .failed("x"), .notApproved] {
                #expect(row(Output(inGroup: false, plays: false, connection: connection)).status == nil)
            }
        }
    }

    @Suite("The Mac's own output")
    struct TheMacsOwnOutput {
        /// There's nowhere else for the sound to go.
        @Test("The Mac's own output alone can't be removed") func theMacsOwnOutputAloneCantBeRemoved() {
            let row = row(Output(isLocal: true, inGroup: true, plays: true), SpeakerMenu.Context(groupCount: 1))
            #expect(row.check == .filled)
            #expect(row.click == nil)
        }

        @Test("The Mac's own output can be removed while speakers play") func theMacsOwnOutputWithSpeakersCanBeRemoved() {
            #expect(row(Output(isLocal: true, inGroup: true, plays: true)).click == .remove)
        }

        /// The Mac's own output is always there to take over, so a speaker can always go.
        @Test("A Sendspin speaker alone can be removed") func aSendspinSpeakerAloneCanBeRemoved() {
            let row = row(Output(inGroup: true, plays: true), SpeakerMenu.Context(groupCount: 1))
            #expect(row.click == .remove)
        }
    }

    @Suite("Groupable or not")
    struct GroupableOrNot {
        /// Without a check, the icon says it plays, as in the Sound menu (one indicator per row).
        @Test("An output that isn't groupable has no check, and a blue icon while it plays") func anOutputThatIsntGroupableHasNoCheckAndABlueIconWhileItPlays() {
            let playing = row(Output(isLocal: true, isGroupable: false, inGroup: true, plays: true),
                                   SpeakerMenu.Context(playsGroupable: false, groupCount: 1))
            #expect(playing.check == .none)
            #expect(playing.click == nil)
            #expect(playing.iconIsBlue)
        }

        /// The check says it; a blue icon too would say it twice.
        @Test("A groupable output's icon never turns blue") func aGroupableOutputsIconNeverTurnsBlue() {
            #expect(!row(Output(inGroup: true, plays: true)).iconIsBlue)
            #expect(!row(Output(isLocal: true, inGroup: true, plays: true)).iconIsBlue)
        }

        /// A check would promise grouping that can't happen: a server plays where it chooses,
        /// and macOS removes an AirPlay output once Sendspin is the Mac's output. The names still
        /// play there.
        @Test("While what plays isn't groupable, nothing can join") func whileWhatPlaysIsntGroupableNothingCanJoin() {
            let context = SpeakerMenu.Context(playsGroupable: false, groupCount: 0)
            let row = row(Output(inGroup: false, plays: false), context)
            #expect(row.check == .none)
            #expect(row.click == nil)
        }

        @Test("Without a check, connecting is said in words") func withoutACheckConnectingIsSaidInWords() {
            let context = SpeakerMenu.Context(playsGroupable: false, groupCount: 1)
            #expect(row(Output(inGroup: true, plays: false, connection: .connecting), context).status == "Connecting…")
        }
    }

    @Suite("Servers")
    struct Sources {
        @Test("A source has no check; its icon is blue while it's the one chosen") func aSourceHasNoCheckAndABlueIconWhileChosen() {
            let chosen = SpeakerMenu.sourceRow(chosen: true, connection: .connected)
            #expect(chosen.check == .none && chosen.click == nil)
            #expect(chosen.iconIsBlue)
            #expect(chosen.status == nil)
            let other = SpeakerMenu.sourceRow(chosen: false, connection: nil)
            #expect(!other.iconIsBlue && other.status == nil && !other.showsWarning)
        }

        /// Choosing it is what pairs it: that's said before.
        @Test("A source that needs pairing says so before it's chosen") func aSourceThatNeedsPairingSaysSoBeforeItsChosen() {
            let row = SpeakerMenu.sourceRow(chosen: false, connection: .pairingRequired)
            #expect(row.status == "Needs pairing")
            #expect(!row.showsWarning)
            #expect(!row.iconIsBlue)
        }

        @Test("What's wrong with the chosen source gets a warning") func whatsWrongWithTheChosenSourceGetsAWarning() {
            let row = SpeakerMenu.sourceRow(chosen: true, connection: .failed("refused"))
            #expect(row.status == "Can't connect" && row.showsWarning && !row.iconIsBlue)
            #expect(SpeakerMenu.sourceRow(chosen: true, connection: .connecting).status == "Connecting…")
            #expect(SpeakerMenu.sourceRow(chosen: false, connection: .failed("refused")).status == nil)
            #expect(SpeakerMenu.sourceRow(chosen: false, connection: nil, isDiscovered: false).status == "Unavailable")
        }
    }

    struct Servers {
        @Test("A server follows the same rules as a speaker") func aServerFollowsTheSameRulesAsASpeaker() {
            let context = SpeakerMenu.Context(groupCount: 0)
            let playing = row(SpeakerMenu.server(chosen: true, connected: true), context)
            #expect(playing.check == .none)
            #expect(playing.iconIsBlue)
            #expect(playing.status == nil)

            let goneWhileChosen = row(SpeakerMenu.server(chosen: true, connected: false), context)
            #expect(!goneWhileChosen.iconIsBlue)
            #expect(goneWhileChosen.status == "Unavailable")
            #expect(goneWhileChosen.showsWarning)

            let goneAndNotChosen = row(SpeakerMenu.server(chosen: false, connected: false), context)
            #expect(goneAndNotChosen.status == "Unavailable")
            #expect(goneAndNotChosen.showsWarning)

            let idle = row(SpeakerMenu.server(chosen: false, connected: true), context)
            #expect(!idle.iconIsBlue)
            #expect(idle.status == nil)
        }

        /// One look for one state: a gone server is a problem even when it isn't chosen, as it's
        /// only listed because it's paired.
        @Test("\"Unavailable\" always shows the warning") func unavailableAlwaysShowsTheWarning() {
            for output in [SpeakerMenu.server(chosen: false, connected: false),
                           SpeakerMenu.server(chosen: true, connected: false),
                           Output(inGroup: true, plays: false, connection: .unavailable),
                           Output(inGroup: false, plays: false, isDiscovered: false, connection: nil)] {
                let row = row(output)
                #expect(row.status == "Unavailable")
                #expect(row.showsWarning)
            }
        }

        @Test("An unavailable server and speaker look the same") func anUnavailableServerAndSpeakerLookTheSame() {
            let server = row(SpeakerMenu.server(chosen: true, connected: false), grouped)
            let speaker = row(Output(isGroupable: false, inGroup: true, plays: false, isDiscovered: false,
                                          connection: nil), grouped)
            #expect(server == speaker)
        }
    }

    @Suite("Choices: adding")
    struct Adding {
        /// Adding starts from what plays now: the Mac plays along, in sync.
        @Test("Adding a speaker to the Mac plays them together, through Sendspin") func addingASpeakerToTheMacPlaysThemTogetherThroughSendspin() {
            #expect(plan(.add("aux"), direct) == SpeakerMenu.Plan(group: [mac, "aux"], route: .speakers))
        }

        /// AirPlay can't play along: macOS removes the device once Sendspin is the output.
        @Test("Adding a speaker while AirPlay plays replaces it") func addingASpeakerWhileAirPlayPlaysReplacesIt() {
            var airPlay = direct
            airPlay.localIsGroupable = false
            #expect(plan(.add("aux"), airPlay) == SpeakerMenu.Plan(group: ["aux"], route: .speakers))
        }

        @Test("Adding the Mac joins the speakers") func addingTheMacJoinsTheSpeakers() {
            let speakerAlone = SpeakerMenu.State(local: mac, group: ["aux"], canPlay: [mac, "aux"])
            #expect(plan(.add(mac), speakerAlone) == SpeakerMenu.Plan(group: [mac, "aux"], route: .speakers))
        }

        @Test("Adding an AirPlay output plays it alone") func addingAnAirPlayOutputPlaysItAlone() {
            let state = SpeakerMenu.State(local: mac, localIsGroupable: false, group: ["aux"], canPlay: [mac, "aux"])
            #expect(plan(.add(mac), state) == SpeakerMenu.Plan(group: [mac], route: .direct))
        }
    }

    @Suite("Choices: removing")
    struct Removing {
        /// Alone, the Mac's own output plays directly: nothing to keep in sync with, no delay.
        @Test("Removing the last Sendspin speaker hands over to the Mac") func removingTheLastSendspinSpeakerHandsOverToTheMac() {
            let speakerAlone = SpeakerMenu.State(local: mac, group: ["aux"], canPlay: [mac, "aux"])
            #expect(plan(.remove("aux"), speakerAlone) == SpeakerMenu.Plan(group: [mac], route: .direct))
            let withTheMac = SpeakerMenu.State(local: mac, group: [mac, "aux"], canPlay: [mac, "aux"])
            #expect(plan(.remove("aux"), withTheMac) == SpeakerMenu.Plan(group: [mac], route: .direct))
        }

        /// Something always plays after a choice; the speakers that can't stay in the group and
        /// join in once they're back.
        @Test("When nothing left can play, the Mac joins and the others wait") func whenNothingLeftCanPlayTheMacJoinsAndTheOthersWait() {
            let state = SpeakerMenu.State(local: mac, group: ["aux", "office"], canPlay: [mac, "aux"])
            #expect(plan(.remove("aux"), state) == SpeakerMenu.Plan(group: [mac, "office"], route: .speakers))
        }

        @Test("Removing a speaker keeps the rest of the group") func removingASpeakerKeepsTheRestOfTheGroup() {
            #expect(plan(.remove("aux"), grouped3) == SpeakerMenu.Plan(group: [mac, "office"], route: .speakers))
        }

        @Test("The Mac alone can't be removed") func theMacAloneCantBeRemoved() {
            #expect(plan(.remove(mac), direct) == nil)
        }

        @Test("The Mac can't leave only unavailable speakers behind") func theMacCantLeaveOnlyUnavailableSpeakersBehind() {
            let state = SpeakerMenu.State(local: mac, group: [mac, "office"], canPlay: [mac])
            #expect(plan(.remove(mac), state) == SpeakerMenu.Plan(group: [mac, "office"], route: .speakers))
        }

        @Test("Removing what isn't in the group changes nothing") func removingWhatIsntInTheGroupChangesNothing() {
            #expect(plan(.remove("pe"), grouped3) == nil)
        }
    }

    @Suite("Choices: clicking a name")
    struct ClickingAName {
        @Test("Clicking the Mac's name plays it directly, alone") func clickingTheMacsNamePlaysItDirectlyAlone() {
            #expect(plan(.playOnly(mac), grouped3) == SpeakerMenu.Plan(group: [mac], route: .direct))
        }

        /// As in the Sound menu: the name chooses one output; the check groups.
        @Test("Clicking a speaker's name plays there only") func clickingASpeakersNamePlaysThereOnly() {
            #expect(plan(.playOnly("aux"), grouped3) == SpeakerMenu.Plan(group: ["aux"], route: .speakers))
        }

        @Test("Clicking an unavailable speaker's name brings the Mac along") func clickingAnUnavailableSpeakersNameBringsTheMacAlong() {
            #expect(plan(.playOnly("office"), grouped3) == SpeakerMenu.Plan(group: [mac, "office"], route: .speakers))
        }
    }

    @Suite("Choices: choosing a server")
    struct ChoosingAServer {
        /// A server can't be grouped with; speakers that stayed in a group nobody plays to
        /// would be stale. Unavailable ones leave the list with it (what you didn't choose, leaves).
        @Test("Choosing a server dissolves the group, unavailable speakers too") func choosingAServerDissolvesTheGroupUnavailableSpeakersToo() {
            #expect(plan(.chooseServer, grouped3) == SpeakerMenu.Plan(group: [], route: .server))
        }

        @Test("A speaker chosen after a server starts a new group") func aSpeakerChosenAfterAServerStartsANewGroup() {
            let server = SpeakerMenu.State(local: mac, group: [], canPlay: [mac, "aux"])
            #expect(plan(.add("aux"), server) == SpeakerMenu.Plan(group: ["aux"], route: .speakers))
        }
    }

    @Suite("The menu bar icon")
    struct MenuBarIcon {
        fileprivate func plays(_ route: SpeakerMenu.Route, sound: Bool = true, speaker: Bool = false,
                               server: Bool = false) -> Bool {
            SpeakerMenu.sendspinPlays(hasSound: sound, route: route, speakerConnected: speaker, serverStreaming: server)
        }

        @Test("Sendspin plays while a connected speaker gets the Mac's sound") func sendspinPlaysWhileAConnectedSpeakerGetsTheMacsSound() {
            #expect(plays(.speakers, speaker: true))
        }

        /// With every speaker in the group unavailable, only the Mac's own speakers play: nothing
        /// goes out over Sendspin. The output stays Sendspin, so the speakers rejoin by themselves.
        @Test("The Mac's own speakers alone aren't Sendspin playing") func theMacsOwnSpeakersAloneArentSendspinPlaying() {
            #expect(!plays(.speakers, speaker: false))
        }

        @Test("Silence isn't playing") func silenceIsntPlaying() {
            #expect(!plays(.speakers, sound: false, speaker: true))
            #expect(!plays(.server, sound: false, server: true))
        }

        @Test("A server plays once its stream is open") func aServerPlaysOnceItsStreamIsOpen() {
            #expect(plays(.server, server: true))
            #expect(!plays(.server, speaker: true))
        }

        @Test("Played directly, Sendspin doesn't play") func playedDirectlySendspinDoesntPlay() {
            #expect(!plays(.direct, speaker: true, server: true))
        }
    }

    @Suite("The dot")
    struct Dot {
        @Test("The dot is blue while Sendspin plays") func theDotIsBlueWhileSendspinPlays() {
            #expect(SpeakerMenu.dot(sendspinIsOutput: true, sendspinPlays: true) == .plays)
        }

        /// The middle state the menu bar icon can't show: Sendspin is the Mac's output, so the
        /// speakers rejoin by themselves, but nothing goes out now. Grey, as a grey check.
        @Test("The dot is grey while Sendspin is the output but nothing goes out") func theDotIsGreyWhileSendspinIsTheOutputButNothingGoesOut() {
            #expect(SpeakerMenu.dot(sendspinIsOutput: true, sendspinPlays: false) == .inUse)
        }

        @Test("The dot is an empty ring while the Mac plays without Sendspin") func theDotIsAnEmptyRingWhileTheMacPlaysWithoutSendspin() {
            #expect(SpeakerMenu.dot(sendspinIsOutput: false, sendspinPlays: false) == .notInUse)
        }
    }
}
