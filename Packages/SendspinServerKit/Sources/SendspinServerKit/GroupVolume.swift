/// Sendspin group volume: the group level is the average of the players' volumes,
/// and changing it shifts every player by the same amount, redistributing whatever
/// a player can't take (clamped at 0 or 100) over the others. Relative differences
/// between players are kept wherever possible. Ported from aiosendspin.
public enum GroupVolume {
    public static func level<Key>(_ volumes: [Key: Int]) -> Int? {
        guard !volumes.isEmpty else { return nil }
        return Int((Double(volumes.values.reduce(0, +)) / Double(volumes.count)).rounded())
    }

    public static func redistribute<Key: Hashable>(_ volumes: [Key: Int], to target: Int) -> [Key: Int] {
        guard !volumes.isEmpty else { return [:] }
        let target = Double(max(0, min(100, target)))
        var levels = volumes.mapValues(Double.init)
        var delta = target - levels.values.reduce(0, +) / Double(levels.count)

        // A pass that clamps nobody has applied all of delta; any other pass drops at
        // least one player, so this ends within one pass per player.
        var active = Array(levels.keys)
        while !active.isEmpty {
            var lost = 0.0
            var stillActive: [Key] = []
            for key in active {
                let proposed = levels[key]! + delta
                let clamped = min(100, max(0, proposed))
                lost += proposed - clamped
                if clamped == proposed { stillActive.append(key) }
                levels[key] = clamped
            }
            if stillActive.count == active.count { break }
            if !stillActive.isEmpty { delta = lost / Double(stillActive.count) }
            active = stillActive
        }
        return levels.mapValues { Int($0.rounded()) }
    }
}
