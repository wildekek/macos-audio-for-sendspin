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
