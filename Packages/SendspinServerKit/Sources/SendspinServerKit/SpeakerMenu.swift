/// The menu's rules for speakers and servers, apart from the app: how a row shows its state,
/// and what a choice in the menu leads to. The rules are `SpeakerMenuTests`, one test per rule
/// with why it is so; `docs/menu-states.md` holds the rest of the menu. The app only carries
/// out the answers.
public enum SpeakerMenu {
    // MARK: Rows

    /// A Sendspin server this Mac is a source for, such as Music Assistant, as an output: it
    /// isn't groupable, it's "in the group" while chosen, and "found" while connected. Its row
    /// follows the same rules as a speaker's: a blue icon while it plays, and when it's gone,
    /// "Unavailable" with a warning, chosen or not.
    public static func server(chosen: Bool, connected: Bool) -> Output {
        Output(isGroupable: false, inGroup: chosen, plays: chosen && connected, isDiscovered: connected,
               connection: connected ? .connected : .unavailable)
    }

    /// What a row knows about its output.
    public struct Output: Equatable, Sendable {
        /// The Mac's own output (its speakers, AirPods, …), not a Sendspin speaker.
        public var isLocal: Bool
        /// It can be in a group: every Sendspin speaker, and the Mac's own output unless it's
        /// AirPlay.
        public var isGroupable: Bool
        /// In the group as the menu shows it: what plays, or added and not playing yet.
        public var inGroup: Bool
        /// It plays the Mac's sound now.
        public var plays: Bool
        /// It's found on the network (a ticked speaker stays listed while it's gone).
        public var isDiscovered: Bool
        public var connection: PlayerStatus.Connection?

        public init(isLocal: Bool = false, isGroupable: Bool = true, inGroup: Bool, plays: Bool,
                    isDiscovered: Bool = true, connection: PlayerStatus.Connection? = .connected) {
            self.isLocal = isLocal
            self.isGroupable = isGroupable
            self.inGroup = inGroup
            self.plays = plays
            self.isDiscovered = isDiscovered
            self.connection = connection
        }
    }

    /// What the menu around a row knows.
    public struct Context: Equatable, Sendable {
        /// What plays now is groupable: not a server, nor an AirPlay output.
        public var playsGroupable: Bool
        /// How many outputs are in the group.
        public var groupCount: Int

        public init(playsGroupable: Bool = true, groupCount: Int) {
            self.playsGroupable = playsGroupable
            self.groupCount = groupCount
        }
    }

    /// How a row shows its state. One indicator per row: the check where the output is
    /// groupable, the blue icon where it isn't.
    public struct Row: Equatable, Sendable {
        public enum Check: Equatable, Sendable {
            /// Not groupable, or what plays isn't: nothing can join.
            case none
            /// Not in the group.
            case empty
            /// In the group and playing.
            case filled
            /// In the group, but it can't play now (gone, taken, refused).
            case grey
            /// In the group and connecting.
            case spinner
        }

        public enum Click: Equatable, Sendable {
            case add, remove
        }

        public var check: Check
        /// What clicking the check does; nil when it does nothing (all that plays).
        public var click: Click?
        /// The icon turns blue while it plays: only where there's no check to say it.
        public var iconIsBlue: Bool
        /// A warning triangle before the status: something is wrong with it.
        public var showsWarning: Bool
        /// Why it can't play, or what it's waiting for; nil while all is well.
        public var status: String?
    }

    public static func row(_ output: Output, in context: Context) -> Row {
        let hasCheck = output.isGroupable && context.playsGroupable
        let problem = Problem(output)
        let check: Row.Check
        if !hasCheck {
            check = .none
        } else if !output.inGroup {
            check = .empty
        } else if output.plays {
            check = .filled
        } else if problem != nil {
            check = .grey
        } else {
            check = .spinner
        }

        let click: Row.Click?
        if !hasCheck {
            click = nil
        } else if output.inGroup {
            // A Sendspin speaker can always go: when nothing left can play, the Mac's own
            // output takes over. The Mac's own output can't when it's all that plays.
            click = !output.isLocal || context.groupCount > 1 ? .remove : nil
        } else {
            click = .add
        }

        // A status that says something is wrong gets the warning, wherever it shows.
        let status = status(output, problem: problem, hasCheck: hasCheck)
        return Row(check: check, click: click,
                   iconIsBlue: !output.isGroupable && output.plays,
                   showsWarning: status != nil && problem?.isWarning == true,
                   status: status)
    }

    /// It can play now, or will once connected: not gone, taken or refused.
    public static func canPlay(_ output: Output) -> Bool { Problem(output) == nil }

    /// Why an output in the menu can't play now.
    private enum Problem {
        case gone, inUseElsewhere, disconnected, cantConnect, needsPairing, identityChanged

        init?(_ output: Output) {
            guard output.isDiscovered else {
                self = .gone
                return
            }
            switch output.connection {
            case .unavailable: self = .gone
            case .taken, .left: self = .inUseElsewhere
            case .disconnected: self = .disconnected
            case .failed: self = .cantConnect
            case .pairingRequired: self = .needsPairing
            case .notApproved: self = .identityChanged
            case .connecting, .connected, .awaitingApproval, nil: return nil
            }
        }

        /// Something is wrong with it. "In use elsewhere" is another server's choice.
        var isWarning: Bool { self != .inUseElsewhere }

        var text: String {
            switch self {
            case .gone: "Unavailable"
            case .inUseElsewhere: "In use elsewhere"
            case .disconnected: "Disconnected"
            case .cantConnect: "Can't connect"
            case .needsPairing: "Needs pairing"
            case .identityChanged: "Identity changed"
            }
        }
    }

    /// Only for what needs attention. A speaker out of the group says nothing, unless it's gone
    /// (only one in the group stays listed then) or another server has it.
    private static func status(_ output: Output, problem: Problem?, hasCheck: Bool) -> String? {
        if !output.isDiscovered { return Problem.gone.text }
        guard output.inGroup || output.connection == .left else { return nil }
        if let problem { return problem.text }
        switch output.connection {
        // Where there's a check, its spinner says it.
        case .connecting, .awaitingApproval, nil: return hasCheck ? nil : "Connecting…"
        default: return nil
        }
    }

    // MARK: Choices

    /// Where the Mac's sound goes.
    public enum Route: Equatable, Sendable {
        /// Through Sendspin, to the outputs in the group.
        case speakers
        /// Straight to the Mac's own output, without Sendspin and its delay.
        case direct
        /// Through a Sendspin server, such as Music Assistant, which plays it where it chooses.
        case server
    }

    /// What the menu shows, as far as choosing goes.
    public struct State: Equatable, Sendable {
        /// The key of the Mac's own output.
        public var local: String
        /// The Mac's own output can be in a group (it isn't AirPlay).
        public var localIsGroupable: Bool
        /// In the group as the menu shows it.
        public var group: Set<String>
        /// Outputs that can play now, or will once connected: not gone, taken or refused.
        public var canPlay: Set<String>

        public init(local: String, localIsGroupable: Bool = true, group: Set<String>, canPlay: Set<String>) {
            self.local = local
            self.localIsGroupable = localIsGroupable
            self.group = group
            self.canPlay = canPlay
        }
    }

    public enum Action: Equatable, Sendable {
        /// Its check, empty: add it.
        case add(String)
        /// Its check, filled: take it out.
        case remove(String)
        /// Its name: play there only, as in the Sound menu.
        case playOnly(String)
        /// A server can't be grouped with: the group dissolves.
        case chooseServer
    }

    /// What a choice leads to: the group, and where the sound goes.
    public struct Plan: Equatable, Sendable {
        public var group: Set<String>
        public var route: Route

        public init(group: Set<String>, route: Route) {
            self.group = group
            self.route = route
        }
    }

    /// What `action` leads to; nil when it changes nothing (the Mac's own output when it's
    /// all that plays can't be taken out).
    public static func plan(_ action: Action, in state: State) -> Plan? {
        switch action {
        case .chooseServer:
            return Plan(group: [], route: .server)

        case .playOnly(let id) where id == state.local:
            return Plan(group: [state.local], route: .direct)

        case .playOnly(let id):
            return settle([id], in: state)

        case .add(let id) where id == state.local:
            guard state.localIsGroupable else { return Plan(group: [state.local], route: .direct) }
            return settle(state.group.union([id]), in: state)

        case .add(let id):
            // Adding starts from what plays now; an AirPlay output can't stay.
            var group = state.group
            if !state.localIsGroupable { group.remove(state.local) }
            return settle(group.union([id]), in: state)

        case .remove(let id):
            guard state.group.contains(id) else { return nil }
            if id == state.local, state.group == [state.local] { return nil }
            return settle(state.group.subtracting([id]), in: state)
        }
    }

    /// Something must be able to play after a choice. With no Sendspin speaker left the Mac's
    /// own output takes over, played directly. With only speakers that can't play now, it
    /// joins them, and they join in once they're back.
    private static func settle(_ group: Set<String>, in state: State) -> Plan {
        let speakers = group.subtracting([state.local])
        if speakers.isEmpty { return Plan(group: [state.local], route: .direct) }
        var group = group
        if state.localIsGroupable, !group.contains(state.local), speakers.isDisjoint(with: state.canPlay) {
            group.insert(state.local)
        }
        return Plan(group: group, route: .speakers)
    }
}
