import Foundation

// Pure helpers behind the Trunked browser: which systems to list, how to group a system's talkgroups, and how a talkgroup
// becomes a codeplug channel. They hold no state and touch no network, so they are tested directly.

/// How the list of systems is narrowed and ordered.
public struct TrunkedSystemFilter: Equatable, Sendable {
    public enum Order: String, CaseIterable, Sendable {
        case activity      // most calls per hour first
        case name
        case location      // by state, then city

        public var label: String {
            switch self {
            case .activity: return "Most active"
            case .name: return "Name"
            case .location: return "State"
            }
        }
    }

    public var search: String = ""
    /// Two-letter state or province codes; empty means every state.
    public var states: Set<String> = []
    /// Lower-cased system types ("p25", "smartnet" ...); empty means every type.
    public var types: Set<String> = []
    public var activeOnly = false
    public var order: Order = .activity

    public init(search: String = "", states: Set<String> = [], types: Set<String> = [], activeOnly: Bool = false,
                order: Order = .activity) {
        self.search = search
        self.states = states
        self.types = types
        self.activeOnly = activeOnly
        self.order = order
    }

    public func apply(to systems: [TrunkedSystem]) -> [TrunkedSystem] {
        let words = search.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let matching = systems.filter { system in
            if activeOnly && !system.isActive { return false }
            if !states.isEmpty && !states.contains(system.state.uppercased()) { return false }
            if !types.isEmpty && !types.contains(system.systemType.lowercased()) { return false }
            guard !words.isEmpty else { return true }
            let haystack = [system.name, system.shortName, system.city, system.county, system.state, system.typeLabel,
                            system.details].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        switch order {
        case .activity:
            return matching.sorted {
                if $0.callsPerHour != $1.callsPerHour { return $0.callsPerHour > $1.callsPerHour }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .name:
            return matching.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .location:
            return matching.sorted {
                if $0.state != $1.state { return $0.state < $1.state }
                if $0.city != $1.city { return $0.city.localizedCaseInsensitiveCompare($1.city) == .orderedAscending }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    /// The states present in a list of systems, for a picker.
    public static func states(in systems: [TrunkedSystem]) -> [String] {
        Set(systems.map { $0.state.uppercased() }.filter { !$0.isEmpty }).sorted()
    }

    /// The system types present in a list of systems (lower-cased), for a picker.
    public static func types(in systems: [TrunkedSystem]) -> [String] {
        Set(systems.map { $0.systemType.lowercased() }.filter { !$0.isEmpty }).sorted()
    }
}

/// One category's talkgroups, in the order they are shown.
public struct TalkgroupGroup: Identifiable, Equatable, Sendable {
    public var category: TalkgroupCategory
    public var talkgroups: [TrunkedTalkgroup]
    public var id: TalkgroupCategory { category }
}

public enum TalkgroupBrowsing {
    /// Talkgroups matching a search and, optionally, one category, grouped by category. Categories come in the order
    /// public-safety listeners expect (law, fire, EMS first, "other" last) and empty categories are left out. Within a
    /// group talkgroups are in numeric order.
    public static func groups(_ talkgroups: [TrunkedTalkgroup], search: String = "",
                              category: TalkgroupCategory? = nil) -> [TalkgroupGroup] {
        let words = search.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var byCategory: [TalkgroupCategory: [TrunkedTalkgroup]] = [:]
        for talkgroup in talkgroups {
            let kind = talkgroup.category
            if let category, kind != category { continue }
            if !words.isEmpty {
                let haystack = [talkgroup.alphaTag, talkgroup.descriptionText, talkgroup.tag, talkgroup.group, String(talkgroup.code)]
                    .joined(separator: " ").lowercased()
                guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            }
            byCategory[kind, default: []].append(talkgroup)
        }
        return TalkgroupCategory.allCases.compactMap { kind in
            guard let list = byCategory[kind], !list.isEmpty else { return nil }
            return TalkgroupGroup(category: kind, talkgroups: list.sorted { $0.code < $1.code })
        }
    }

    /// How many talkgroups fall in each category, for the filter chips.
    public static func counts(_ talkgroups: [TrunkedTalkgroup]) -> [TalkgroupCategory: Int] {
        talkgroups.reduce(into: [:]) { $0[$1.category, default: 0] += 1 }
    }
}

extension CodeplugChannel {
    /// A channel for a talkgroup on a trunked system. It has no frequency: the scanner follows the system's own control
    /// channel, and the validator says so (and warns when the chosen radio cannot follow trunked systems at all).
    public static func talkgroup(_ talkgroup: TrunkedTalkgroup, on system: TrunkedSystem) -> CodeplugChannel {
        let mode: ChannelMode
        switch system.systemType.lowercased() {
        case "dmr": mode = .dmr
        default: mode = .p25
        }
        var notes = system.name
        if !talkgroup.descriptionText.isEmpty && talkgroup.descriptionText != talkgroup.displayName {
            notes += ": " + talkgroup.descriptionText
        }
        return CodeplugChannel(name: talkgroup.displayName, frequencyHz: 0, mode: mode, talkgroupID: talkgroup.code,
                               notes: notes, sourceCallSign: system.shortName)
    }
}

extension Codeplug {
    /// Adds talkgroups of a system as channels, skipping ones this codeplug already has for that system. Returns how many
    /// were added.
    @discardableResult
    public mutating func addTalkgroups(_ talkgroups: [TrunkedTalkgroup], on system: TrunkedSystem) -> Int {
        var have = Set(channels.filter { $0.talkgroupID > 0 }.map { "\($0.sourceCallSign)|\($0.talkgroupID)" })
        var fresh: [CodeplugChannel] = []
        for talkgroup in talkgroups.sorted(by: { $0.code < $1.code }) {
            let key = "\(system.shortName)|\(talkgroup.code)"
            guard have.insert(key).inserted else { continue }
            fresh.append(CodeplugChannel.talkgroup(talkgroup, on: system))
        }
        if !fresh.isEmpty { insert(fresh) }
        return fresh.count
    }
}
