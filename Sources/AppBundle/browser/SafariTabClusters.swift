import Foundation

/// What a Safari tab button's identifier says about the topic it heads or is in. Safari 27
/// gathers tabs into suggested topics, which aren't Tab Groups: a topic shows in the tab bar as
/// a button with its name and how many tabs it has, which opens or closes it, and its tabs follow
/// it while it's open. That button has a tab's role and subrole; only its identifier tells it
/// apart. Safari doesn't document it, so an identifier this doesn't recognize says nothing.
enum SafariTabCluster: Equatable, Sendable {
    /// No identifier, or one that doesn't speak of topics, as before Safari 27.
    case unknown
    /// A tab that says it's in no topic.
    case plain
    /// A topic's own button, never a page: it has `tabCount` tabs, shown while it's expanded.
    case header(id: String, isExpanded: Bool, tabCount: Int)
    /// A tab in the topic `id`.
    case member(id: String)
    /// Speaks of topics, but doesn't say consistently what this is: maybe a topic's button.
    case malformed

    init(identifier: String?) {
        guard let fields = safariTabIdentifierFields(identifier) else {
            self = .unknown
            return
        }
        var values: [String: String] = [:]
        for (name, field) in fields {
            guard case .value(let value) = field else {
                self = .malformed
                return
            }
            values[name] = value
        }
        let clusterID = values["clusterID"].flatMap { $0.isEmpty ? nil : $0 }
        switch values["isCluster"] {
            case "true":
                guard let clusterID, let isExpanded = ["true": true, "false": false][values["isExpanded"] ?? ""],
                      let tabCount = values["tabCount"].flatMap({ Int($0) }), tabCount > 0
                else {
                    self = .malformed
                    return
                }
                self = .header(id: clusterID, isExpanded: isExpanded, tabCount: tabCount)
            case "false":
                // A tab names its topic, or names none with an empty id; without the id, it says neither.
                self = clusterID.map { .member(id: $0) } ?? (values["clusterID"] == nil ? .unknown : .plain)
            case nil:
                // Without saying whether it's a topic's button, a topic's id doesn't say what this is.
                self = clusterID == nil ? .unknown : .malformed
            default:
                self = .malformed
        }
    }

    /// Whether this can be a page: anything but a topic's own button, or what may be one.
    var isPage: Bool {
        switch self {
            case .header, .malformed: false
            case .unknown, .plain, .member: true
        }
    }
}

/// A field of a Safari tab button's identifier: its value, or a sign it can't be read.
private enum SafariTabIdentifierField: Equatable {
    case value(String)
    /// Named twice, or named without a value.
    case unreadable
}

/// The topic fields of a Safari tab button's identifier, which Safari 27.0 writes as
/// "TabBarTab?isNarrow=false&isExpanded=true&tabCount=4&isPinned=false&isCluster=true&clusterID=<UUID>&isActive=false"
/// for a topic's own button, and with `isCluster=false`, an empty `tabCount` and the topic's
/// `clusterID`, or an empty one, for a tab. Nil for anything else, or one without them. Other
/// fields, and the fields' order, don't matter here.
private func safariTabIdentifierFields(_ identifier: String?) -> [String: SafariTabIdentifierField]? {
    let prefix = "TabBarTab?"
    let names: Set = ["isCluster", "clusterID", "isExpanded", "tabCount"]
    guard let identifier, identifier.hasPrefix(prefix) else { return nil }
    var fields: [String: SafariTabIdentifierField] = [:]
    for pair in identifier.dropFirst(prefix.count).split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        guard names.contains(name) else { continue }
        fields[name] = fields[name] == nil && parts.count == 2 ? .value(String(parts[1])) : .unreadable
    }
    return fields["isCluster"] == nil && fields["clusterID"] == nil ? nil : fields
}

/// Whether a Safari tab bar's buttons account for every tab of each topic they show: each topic
/// open, listing as many tabs as it says it has, and each tab in a topic listed with its topic's
/// button. A tab bar without topics does. Only then do the tabs listed stand one for one, in the
/// tab bar's order, for the window's: a closed topic's tabs are missing, and otherwise which
/// button is which isn't known.
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
