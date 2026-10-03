import Foundation

/// What a Safari tab button's identifier says about the topic it heads or is in. Safari 27
/// gathers tabs into suggested topics, which aren't Tab Groups: a topic shows in the tab bar as
/// a button with its name and how many tabs it has, which opens or closes it, and its tabs follow
/// it while it's open. That button has a tab's role and subrole; only its identifier tells it
/// apart. Safari doesn't document it, so an identifier this doesn't recognize says nothing, and
/// nothing it says can be taken for a tab's unless it says it all consistently.
enum SafariTabCluster: Equatable, Sendable {
    /// No identifier, or one that doesn't speak of topics, as before Safari 27. That alone doesn't
    /// make it a tab: a topic's button whose identifier changed would say as little.
    case unknown
    /// A tab that says it's in no topic.
    case plain
    /// A topic's own button, never a page: it has `tabCount` tabs, shown while it's expanded.
    case header(id: String, isExpanded: Bool, tabCount: Int)
    /// A tab in the topic `id`.
    case member(id: String)
    /// Speaks of topics, but not consistently, or its identifier couldn't be read: maybe a topic's
    /// button.
    case malformed

    /// Safari 27.0 writes a topic's own button's identifier as
    /// "TabBarTab?isNarrow=false&isExpanded=true&tabCount=4&isPinned=false&isCluster=true&clusterID=<UUID>&isActive=false",
    /// and a tab's with `isExpanded=false`, an empty `tabCount`, `isCluster=false` and its topic's
    /// `clusterID`, or an empty one. The fields' order, and fields not named here, don't matter.
    init(identifier: String?) {
        let prefix = "TabBarTab?"
        guard let identifier, identifier.hasPrefix(prefix) else {
            self = .unknown
            return
        }
        var fields: [Substring: Substring] = [:]
        for pair in identifier.dropFirst(prefix.count).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard safariTabFlagFields.contains(parts[0]) || safariTabTopicFields.contains(parts[0]) else { continue }
            // Named twice, or without a value: what it says can't be read.
            guard parts.count == 2, fields.updateValue(parts[1], forKey: parts[0]) == nil else {
                self = .malformed
                return
            }
        }
        let tabCount = fields["tabCount"].flatMap { $0.isEmpty ? nil : Int($0) }
        guard safariTabFlagFields.allSatisfy({ fields[$0].map { $0 == "true" || $0 == "false" } ?? true }),
              fields["tabCount"].map({ $0.isEmpty || tabCount.map { $0 > 0 } == true }) ?? true
        else {
            self = .malformed
            return
        }
        guard safariTabTopicFields.contains(where: { fields[$0] != nil }) else {
            self = .unknown
            return
        }
        guard let isCluster = fields["isCluster"], let clusterID = fields["clusterID"] else {
            self = .malformed
            return
        }
        if isCluster == "true" {
            guard !clusterID.isEmpty, let tabCount, let isExpanded = fields["isExpanded"] else {
                self = .malformed
                return
            }
            self = .header(id: String(clusterID), isExpanded: isExpanded == "true", tabCount: tabCount)
        } else {
            // Only a topic's own button has a count or opens; every tab Safari 27.0 listed said neither.
            guard tabCount == nil, fields["isExpanded"] != "true" else {
                self = .malformed
                return
            }
            self = clusterID.isEmpty ? .plain : .member(id: String(clusterID))
        }
    }

    /// What a listed control's identifier says, as just read.
    init(_ structure: BrowserTabAXStructure) {
        self = structure.identifierUnreadable ? .malformed : .init(identifier: structure.identifier)
    }

    /// Whether this can be a page: anything but a topic's own button, or what may be one.
    var isPage: Bool {
        switch self {
            case .header, .malformed: false
            case .unknown, .plain, .member: true
        }
    }
}

/// Whether a Safari of this version (its `CFBundleShortVersionString`) can show topics, which came
/// with Safari 27. Only a version that reads plainly as one before 27, one to three numbers of
/// ASCII digits between dots, the first above 0, says it can't; any other may be anything.
func safariShowsTopics(version: String?) -> Bool {
    guard let parts = version?.split(separator: ".", omittingEmptySubsequences: false), (1...3).contains(parts.count) else { return true }
    let numbers = parts.compactMap { part in part.utf8.allSatisfy { (0x30...0x39).contains($0) } ? Int(part) : nil }
    guard numbers.count == parts.count, numbers[0] > 0 else { return true }
    return numbers[0] >= 27
}

/// The version of the app at `bundlePath`, as its bundle says.
func appBundleVersion(_ bundlePath: String?) -> String? {
    bundlePath.flatMap { Bundle(path: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
}

/// A Safari tab button identifier's fields that are `true` or `false`.
private let safariTabFlagFields: Set<Substring> = ["isNarrow", "isExpanded", "isPinned", "isCluster", "isActive"]
/// The fields that speak of topics.
private let safariTabTopicFields: Set<Substring> = ["isExpanded", "tabCount", "isCluster", "clusterID"]

/// Whether a Safari tab bar's buttons account for every tab of each topic they show: each topic
/// open, listing as many tabs as it says it has, and each tab in a topic listed with its topic's
/// button. A tab bar without topics does. Only then do the tabs listed stand one for one, in the
/// tab bar's order, for the window's: a closed topic's tabs are missing, and otherwise which
/// button is which isn't known. `.unknown` here must stand for a tab known some other way.
func safariTabClustersAccountedFor(_ clusters: [SafariTabCluster]) -> Bool {
    var headers: [String: Int] = [:]
    var members: [String: Int] = [:]
    var unknown = false
    for cluster in clusters {
        switch cluster {
            case .malformed: return false
            case .unknown: unknown = true
            case .plain: break
            case .header(let id, let isExpanded, let tabCount):
                guard isExpanded, headers[id] == nil else { return false }
                headers[id] = tabCount
            case .member(let id): members[id, default: 0] += 1
        }
    }
    return headers.isEmpty && members.isEmpty || !unknown && headers == members
}
