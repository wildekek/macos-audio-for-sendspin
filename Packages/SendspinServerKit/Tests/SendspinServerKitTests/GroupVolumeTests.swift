import Testing
@testable import SendspinServerKit

struct GroupVolumeTests {
    @Test func levelIsAverage() {
        #expect(GroupVolume.level(["a": 20, "b": 61]) == 41)
        #expect(GroupVolume.level([String: Int]()) == nil)
    }

    @Test func shiftKeepsRelativeDifferences() {
        #expect(GroupVolume.redistribute(["a": 20, "b": 40], to: 40) == ["a": 30, "b": 50])
    }

    @Test func clampedPlayerPassesRemainderToOthers() {
        // Average 50 → 80 is +30; "a" can only take +10, so "b" takes the other +20.
        let result = GroupVolume.redistribute(["a": 90, "b": 10], to: 80)
        #expect(result == ["a": 100, "b": 60])
        #expect(GroupVolume.level(result) == 80)
    }

    @Test func clampsTargetToRange() {
        #expect(GroupVolume.redistribute(["a": 50], to: 150) == ["a": 100])
        #expect(GroupVolume.redistribute(["a": 50, "b": 30], to: -10) == ["a": 0, "b": 0])
    }
}

struct ControllerStateTests {
    static func player(_ volume: Int, muted: Bool = false, volumeCommand: Bool = true, muteCommand: Bool = true)
        -> ControllerMember {
        ControllerMember(inGroup: true, volume: volume, muted: muted, canSetVolume: volumeCommand, canMute: muteCommand)
    }

    /// Only players that take the command count (Reading group volume, Reading group mute).
    @Test func countsOnlyPlayersThatTakeTheCommand() {
        let state = ControllerState(group: [Self.player(80, muted: true), Self.player(30, muted: true),
                                            Self.player(0, muted: false, volumeCommand: false, muteCommand: false)])
        #expect(state.volume == 55)
        #expect(state.muted)
        #expect(state.supportedCommands == ["volume", "mute", "switch"])
        #expect(!ControllerState(group: [Self.player(50, muted: true), Self.player(50)]).muted)
    }

    @Test func withoutVolumeOrMuteThoseAreNotOffered() {
        let state = ControllerState(group: [Self.player(20, muted: true, volumeCommand: false, muteCommand: false)])
        #expect(state == ControllerState(supportedCommands: ["switch"], volume: 100, muted: false))
    }
}
