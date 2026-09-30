import Foundation

extension Codeplug {
    /// Moves channels the way a list's drag-to-reorder does: the ones at `source` go to just before `destination`
    /// (an index into the list as it is now).
    public mutating func moveChannels(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().filter { channels.indices.contains($0) }.map { channels[$0] }
        guard !moving.isEmpty else { return }
        let shift = source.filter { $0 < destination }.count
        for index in source.sorted().reversed() where channels.indices.contains(index) { channels.remove(at: index) }
        let insertion = max(0, min(channels.count, destination - shift))
        channels.insert(contentsOf: moving, at: insertion)
        updatedAt = Date()
    }

    /// Replaces the channel with the same ID.
    public mutating func update(_ channel: CodeplugChannel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        channels[index] = channel
        updatedAt = Date()
    }

    public mutating func insert(_ newChannels: [CodeplugChannel]) {
        channels.append(contentsOf: newChannels)
        updatedAt = Date()
    }

    /// A copy of a channel right after the original.
    public mutating func duplicate(channelID: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        var copy = channels[index]
        copy.id = UUID()
        channels.insert(copy, at: index + 1)
        updatedAt = Date()
    }

    /// Channels in ascending frequency order (talkgroup-only channels last, in their current order).
    public mutating func sortByFrequency() {
        let withFrequency = channels.filter { $0.frequencyHz > 0 }.sorted { $0.frequencyHz < $1.frequencyHz }
        let without = channels.filter { $0.frequencyHz <= 0 }
        channels = withFrequency + without
        updatedAt = Date()
    }

    /// Removes channels that repeat an earlier one (same frequency, offset, mode and tone). Returns how many.
    @discardableResult
    public mutating func removeDuplicates() -> Int {
        var seen = Set<String>()
        var kept: [CodeplugChannel] = []
        for channel in channels {
            guard channel.frequencyHz > 0 else { kept.append(channel); continue }
            let key = String(format: "%.0f|%.0f|%@|%.1f|%d", channel.frequencyHz, channel.offsetHz, channel.mode.rawValue,
                             channel.ctcssToneHz, channel.dtcsCode)
            if seen.insert(key).inserted { kept.append(channel) }
        }
        let removed = channels.count - kept.count
        if removed > 0 {
            channels = kept
            updatedAt = Date()
        }
        return removed
    }

    /// Makes the codeplug fit its radio: names shortened to what the radio shows (kept distinct), channels beyond its
    /// capacity dropped. Returns what changed.
    @discardableResult
    public mutating func fitToRadio() -> (shortenedNames: Int, dropped: Int) {
        var shortened = 0
        var used = Set<String>()
        for index in channels.indices {
            let original = channels[index].name
            let fitted = Self.fittedName(original, limit: target.maxNameLength, taken: used)
            if fitted != original.trimmingCharacters(in: .whitespaces) { shortened += 1 }
            channels[index].name = fitted
            used.insert(fitted.lowercased())
        }
        var dropped = 0
        if channels.count > target.channelCapacity {
            dropped = channels.count - target.channelCapacity
            channels.removeLast(dropped)
        }
        if shortened > 0 || dropped > 0 { updatedAt = Date() }
        return (shortened, dropped)
    }

    /// A name of at most `limit` characters, plain ASCII, not in `taken` (compared without regard to case): a clash gets
    /// a digit at the end ("POLICE" becomes "POLIC2").
    static func fittedName(_ name: String, limit: Int, taken: Set<String>) -> String {
        let ascii = String(name.unicodeScalars.filter { $0.isASCII && $0.value >= 32 }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        var candidate = String(ascii.prefix(limit)).trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty, taken.contains(candidate.lowercased()) else { return candidate }
        for number in 2...99 {
            let suffix = String(number)
            candidate = String(ascii.prefix(max(0, limit - suffix.count))).trimmingCharacters(in: .whitespaces) + suffix
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return candidate
    }

    /// How many channels are in each named band, biggest first.
    public var bandSummary: [(band: String, count: Int)] {
        var counts: [String: Int] = [:]
        for channel in channels { counts[RadioBand.name(for: channel.frequencyHz), default: 0] += 1 }
        return counts.map { (band: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.band < $1.band }
    }
}
