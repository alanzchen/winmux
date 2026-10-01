import Foundation
import NaturalLanguage

/// One tab's evidence and the model's tags for it, as the policy sees them.
struct WorkspaceTopicPolicyItem: Sendable {
    let evidence: WorkspaceTopicEvidence
    let tags: [String]
    var token: WorkspaceTopicToken { evidence.token }
}

/// Turns tags into groups with fixed, testable rules. The model never picks members: a group is
/// a set of tabs that all share one specific word or tag, and anything unclear stays where it is.
///
/// Thresholds come from the P0 samples (anonymous English, Chinese and mixed titles). They're
/// policy scores, not probabilities.
enum WorkspaceTopicPolicy {
    static let version = 1
    /// The least similarity for two tabs to count as linked.
    static let minimumLink = 0.5
    static let maximumNameLength = 40

    /// Groups of at least two tabs, each tab in at most one. Deterministic for the same input.
    nonisolated static func groups(for items: [WorkspaceTopicPolicyItem]) -> [WorkspaceTopicSuggestedGroup] {
        let profiles = items.map { WorkspaceTopicProfile($0) }
        guard profiles.count >= 2 else { return [] }
        var frequency: [String: Int] = [:]
        for profile in profiles { for key in profile.features.keys { frequency[key, default: 0] += 1 } }
        let weight = { (key: String) -> Double in
            // A word half the tabs share says less about any two of them.
            let count = frequency[key] ?? 0
            return count <= 2 || Double(count) <= Double(profiles.count) * 0.5 ? 1 : 0.7
        }
        let count = profiles.count
        var similarity = Array(repeating: Array(repeating: 0.0, count: count), count: count)
        for i in 0 ..< count {
            for j in (i + 1) ..< count {
                let value = profiles[i].similarity(to: profiles[j], weight: weight)
                similarity[i][j] = value
                similarity[j][i] = value
            }
        }

        var assigned: Set<Int> = []
        var groups: [(members: [Int], key: String)] = []
        while true {
            let candidates = candidateGroups(profiles, similarity: similarity, excluding: assigned)
            guard let best = candidates.first else { break }
            groups.append(best)
            assigned.formUnion(best.members)
        }

        // A tab that's as close to a tab outside its group as to its own is ambiguous: leave it.
        var result: [WorkspaceTopicSuggestedGroup] = []
        for group in groups {
            let members = group.members.filter { member in
                let own = group.members.filter { $0 != member }.map { similarity[member][$0] }.max() ?? 0
                let other = (0 ..< count).filter { !group.members.contains($0) }.map { similarity[member][$0] }.max() ?? 0
                return !(other >= minimumLink && other >= own * 0.9)
            }
            guard members.count >= 2 else { continue }
            let memberProfiles = members.map { profiles[$0] }
            guard let name = groupName(memberProfiles, definingKey: group.key, frequency: frequency) else { continue }
            let normalizedName = workspaceTopicNormalize(name)
            let shared = sharedSurfaces(memberProfiles).filter {
                let normalized = workspaceTopicNormalize($0)
                return !normalized.contains(normalizedName) && !normalizedName.contains(normalized)
            }
            result.append(WorkspaceTopicSuggestedGroup(id: result.count, name: name,
                members: members.map { profiles[$0].token }.sorted(), sharedEvidence: Array(shared.prefix(3))))
        }
        return result
    }

    /// Every valid group one shared feature defines among the unassigned tabs, best first.
    private nonisolated static func candidateGroups(_ profiles: [WorkspaceTopicProfile], similarity: [[Double]],
                                                    excluding assigned: Set<Int>) -> [(members: [Int], key: String)] {
        var keys: Set<String> = []
        for (index, profile) in profiles.enumerated() where !assigned.contains(index) { keys.formUnion(profile.features.keys) }
        var candidates: [(members: [Int], key: String, score: Double)] = []
        for key in keys {
            let members = profiles.indices.filter { !assigned.contains($0) && profiles[$0].canJoin(on: key) }
            guard members.count >= 2 else { continue }
            let memberProfiles = members.map { profiles[$0] }
            // Model and titles must agree: a tag in two of them, or a title word across apps.
            let fromModel = memberProfiles.filter { $0.features[key]?.fromModel == true }.count
            let apps = Set(memberProfiles.map(\.appSignature))
            guard fromModel >= 2 || apps.count >= 2 else { continue }
            // The same app alone isn't a topic: tabs of one app need two independent shared roots.
            if apps.count < 2, workspaceTopicIndependentRoots(sharedKeys(memberProfiles)).count < 2 { continue }
            // Sharing one word isn't enough: every two members must be linked, so "A is like B and
            // B is like C" never pulls A and C together. The least linked member goes first.
            var coherent = members
            while true {
                let weakLinks = coherent.map { member in coherent.filter { $0 != member && similarity[member][$0] < minimumLink }.count }
                guard let worst = weakLinks.max(), worst > 0 else { break }
                let candidates = coherent.indices.filter { weakLinks[$0] == worst }
                let drop = candidates.min { lhs, rhs in
                    let left = coherent.map { similarity[coherent[lhs]][$0] }.reduce(0, +)
                    let right = coherent.map { similarity[coherent[rhs]][$0] }.reduce(0, +)
                    return left != right ? left < right : coherent[lhs] > coherent[rhs]
                }!
                coherent.remove(at: drop)
            }
            guard coherent.count >= 2 else { continue }
            let total = coherent.reduce(0.0) { sum, member in
                sum + coherent.filter { $0 != member }.map { similarity[member][$0] }.reduce(0, +)
            }
            guard total / Double(coherent.count * (coherent.count - 1)) >= minimumLink else { continue }
            candidates.append((coherent, key, total / 2))
        }
        // Strongest first, then bigger, then the more specific feature, the same order every time.
        return candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.members.count != $1.members.count { return $0.members.count > $1.members.count }
            return $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key
        }.map { ($0.members, $0.key) }
    }

    private nonisolated static func sharedKeys(_ profiles: [WorkspaceTopicProfile]) -> [String] {
        guard let first = profiles.first else { return [] }
        return first.features.keys.filter { key in profiles.allSatisfy { $0.features[key] != nil } }.sorted()
    }

    private nonisolated static func sharedSurfaces(_ profiles: [WorkspaceTopicProfile]) -> [String] {
        let keys = workspaceTopicIndependentRoots(sharedKeys(profiles))
        return keys.compactMap { key in profiles.lazy.compactMap { $0.features[key]?.surface }.first }
    }

    /// The most specific tag every member's tags or titles contain, else the shared feature fewest
    /// other tabs have: a word every tab shares names nothing.
    private nonisolated static func groupName(_ profiles: [WorkspaceTopicProfile], definingKey: String,
                                              frequency: [String: Int]) -> String? {
        var candidates: [String] = []
        for profile in profiles { candidates += profile.tagSurfaces }
        let contained = candidates.filter { tag in
            let normalized = workspaceTopicNormalize(tag)
            return profiles.allSatisfy { $0.searchTexts.contains { $0.contains(normalized) } }
        }
        let byLength = contained.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0 < $1
        }
        let shared = sharedKeys(profiles).sorted {
            let left = frequency[$0] ?? 0, right = frequency[$1] ?? 0
            if left != right { return left < right }
            if $0.hasPrefix("t:") != $1.hasPrefix("t:") { return $0.hasPrefix("t:") }
            return $0.count != $1.count ? $0.count > $1.count : $0 < $1
        }
        let surfaces = (shared.isEmpty ? [definingKey] : shared).compactMap { key in profiles.lazy.compactMap { $0.features[key]?.surface }.first }
        for name in byLength + surfaces {
            if let valid = workspaceTopicValidatedGroupName(name), !profiles.contains(where: { $0.isAppName(valid) }) { return valid }
        }
        return nil
    }
}

/// A group name as the user will see it, or nil when it's empty, generic, too long, or not words.
nonisolated func workspaceTopicValidatedGroupName(_ raw: String, maximumLength: Int = WorkspaceTopicPolicy.maximumNameLength) -> String? {
    let cleaned = workspaceTopicSanitizedText(raw)
    guard (2 ... maximumLength).contains(cleaned.count),
          cleaned.contains(where: { $0.isLetter }),
          !workspaceTopicIsGeneric(workspaceTopicNormalize(cleaned)) else { return nil }
    return cleaned
}

/// No control or format characters, single spaces, trimmed.
nonisolated func workspaceTopicSanitizedText(_ raw: String) -> String {
    let scalars = raw.unicodeScalars.map { scalar -> Character in
        switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: " "
            default: Character(scalar)
        }
    }
    return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// For comparison only: compatibility forms folded (full-width letters), lowercase, single spaces.
nonisolated func workspaceTopicNormalize(_ text: String) -> String {
    workspaceTopicSanitizedText(text.precomposedStringWithCompatibilityMapping.lowercased())
}

/// Shared features where neither contains the other: "kyoto itinerary" and "kyoto" are one root.
nonisolated func workspaceTopicIndependentRoots(_ keys: [String]) -> [String] {
    let texts = keys.map { String($0.dropFirst(2)) }
    var roots: [String] = []
    var rootTexts: [String] = []
    for (key, text) in zip(keys, texts).sorted(by: { $0.1.count != $1.1.count ? $0.1.count > $1.1.count : $0.0 < $1.0 }) {
        if rootTexts.contains(where: { $0.contains(text) || text.contains($0) }) { continue }
        roots.append(key)
        rootTexts.append(text)
    }
    return roots.sorted()
}

struct WorkspaceTopicFeature: Sendable {
    var surface: String
    var fromModel: Bool
    var fromTitle: Bool
    var isWholeTag: Bool
}

/// A tab reduced to the words that could say what it's about.
struct WorkspaceTopicProfile: Sendable {
    let token: WorkspaceTopicToken
    /// "t:" whole tags, "w:" words, both normalized.
    private(set) var features: [String: WorkspaceTopicFeature] = [:]
    let tagSurfaces: [String]
    /// Normalized titles and tags, each on its own, for checking that a name fits every member.
    let searchTexts: [String]
    /// The tab's apps, so tabs of one app can be told from tabs of several.
    let appSignature: String
    /// A split whose windows are about unrelated things: words each window has.
    private let windowWords: [Set<String>]
    private let appWords: Set<String>

    nonisolated init(_ item: WorkspaceTopicPolicyItem) {
        token = item.token
        let evidence = item.evidence
        appSignature = Set(evidence.windows.map { $0.bundleId ?? $0.appName }).sorted().joined(separator: ",")
        var appWords: Set<String> = []
        for window in evidence.windows {
            let name = workspaceTopicNormalize(window.appName)
            appWords.insert(name)
            for word in name.split(separator: " ") { appWords.insert(String(word)) }
            if let last = window.bundleId?.split(separator: ".").last { appWords.insert(workspaceTopicNormalize(String(last))) }
        }
        self.appWords = appWords
        var tagSurfaces: [String] = []
        var features: [String: WorkspaceTopicFeature] = [:]
        func add(_ key: String, _ surface: String, model: Bool, wholeTag: Bool) {
            if var existing = features[key] {
                existing.fromModel = existing.fromModel || model
                existing.fromTitle = existing.fromTitle || !model
                if wholeTag { existing.isWholeTag = true; existing.surface = surface }
                features[key] = existing
            } else {
                features[key] = .init(surface: surface, fromModel: model, fromTitle: !model, isWholeTag: wholeTag)
            }
        }
        for raw in item.tags {
            let surface = workspaceTopicSanitizedText(raw)
            let normalized = workspaceTopicNormalize(surface)
            guard workspaceTopicIsUsefulPhrase(normalized, appWords: appWords) else { continue }
            tagSurfaces.append(surface)
            add("t:" + normalized, surface, model: true, wholeTag: true)
            for word in workspaceTopicWords(in: surface) where workspaceTopicIsUsefulWord(word.normalized, appWords: appWords) {
                add("w:" + word.normalized, word.surface, model: true, wholeTag: false)
            }
        }
        var windowWords: [Set<String>] = []
        let titles = evidence.windows.map(\.title) + [evidence.label].compactMap(\.self)
        for (index, title) in titles.enumerated() {
            var words: Set<String> = []
            for word in workspaceTopicWords(in: title) where workspaceTopicIsUsefulWord(word.normalized, appWords: appWords) {
                add("w:" + word.normalized, word.surface, model: false, wholeTag: false)
                words.insert(word.normalized)
            }
            // The label belongs to the whole tab, not to one of its windows.
            if index < evidence.windows.count, !words.isEmpty { windowWords.append(words) }
        }
        self.windowWords = windowWords
        self.tagSurfaces = tagSurfaces
        self.features = features
        searchTexts = (titles + item.tags).map(workspaceTopicNormalize)
    }

    /// Windows with distinctive words that share none with each other.
    var isMixed: Bool {
        for i in windowWords.indices {
            for j in windowWords.indices where j > i && windowWords[i].isDisjoint(with: windowWords[j]) { return true }
        }
        return false
    }

    /// A mixed split stays out of every group, even when its other topic has no peer here: its
    /// tags can't say which of its windows they describe.
    nonisolated func canJoin(on key: String) -> Bool {
        features[key] != nil && !isMixed
    }

    nonisolated func isAppName(_ name: String) -> Bool { appWords.contains(workspaceTopicNormalize(name)) }

    nonisolated func similarity(to other: Self, weight: (String) -> Double) -> Double {
        var total = 0.0
        for (key, mine) in features {
            guard let theirs = other.features[key] else { continue }
            let strength: Double = if mine.isWholeTag && theirs.isWholeTag { 1.0 }
                else if mine.fromModel && theirs.fromModel { 0.8 }
                else if mine.fromModel || theirs.fromModel { 0.6 }
                else { 0.5 }
            total += strength * weight(key)
        }
        return total
    }
}

struct WorkspaceTopicWord: Sendable {
    let surface: String
    let normalized: String
}

/// Words and compound names in a title: "tiling-app", "SidebarModel" (no extension), and
/// segmented Chinese words, plus short CJK runs whole, as "季度预算".
nonisolated func workspaceTopicWords(in text: String) -> [WorkspaceTopicWord] {
    let separators = CharacterSet(charactersIn: "—–|·•:;,/\\()[]{}<>\"'“”‘’《》「」【】（）：，。；、!?！？…#*@")
        .union(.whitespacesAndNewlines)
    var result: [WorkspaceTopicWord] = []
    var seen: Set<String> = []
    let tokenizer = NLTokenizer(unit: .word)
    func append(_ surface: Substring) {
        var surface = String(surface).trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        if let dot = surface.lastIndex(of: "."), workspaceTopicFileExtensions.contains(surface[surface.index(after: dot)...].lowercased()) {
            surface = String(surface[..<dot])
        }
        let normalized = workspaceTopicNormalize(surface)
        guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
        result.append(.init(surface: surface, normalized: normalized))
    }
    for chunk in text.components(separatedBy: separators) where !chunk.isEmpty {
        let isCompound = chunk.contains(where: { $0 == "-" || $0 == "_" || $0 == "." }) && chunk.contains(where: \.isLetter)
        let isShortCJK = chunk.unicodeScalars.allSatisfy(workspaceTopicIsCJK) && (2 ... 8).contains(chunk.count)
        if isCompound || isShortCJK { append(Substring(chunk)) }
        tokenizer.string = chunk
        tokenizer.enumerateTokens(in: chunk.startIndex ..< chunk.endIndex) { range, _ in
            append(chunk[range])
            return true
        }
    }
    return result
}

nonisolated func workspaceTopicIsCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
        case 0x3040 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0xAC00 ... 0xD7AF: true
        default: false
    }
}

nonisolated func workspaceTopicIsUsefulWord(_ normalized: String, appWords: Set<String>) -> Bool {
    let isCJK = normalized.unicodeScalars.contains(where: workspaceTopicIsCJK)
    guard normalized.count >= (isCJK ? 2 : 3), normalized.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
    guard !appWords.contains(normalized), !workspaceTopicIsGeneric(normalized),
          !workspaceTopicFileExtensions.contains(normalized) else { return false }
    // Window sizes, years and short numbers say nothing about a topic; a course code may.
    if normalized.allSatisfy(\.isNumber) {
        let isYear = normalized.count == 4 && (normalized.hasPrefix("19") || normalized.hasPrefix("20"))
        return normalized.count >= 4 && !isYear
    }
    if normalized.range(of: #"^\d+\s*[x×]\s*\d+$"#, options: .regularExpression) != nil { return false }
    return true
}

nonisolated func workspaceTopicIsUsefulPhrase(_ normalized: String, appWords: Set<String>) -> Bool {
    guard normalized.count >= 2, normalized.contains(where: \.isLetter) else { return false }
    return !appWords.contains(normalized) && !workspaceTopicIsGeneric(normalized) && !workspaceTopicFileExtensions.contains(normalized)
}

nonisolated func workspaceTopicIsGeneric(_ normalized: String) -> Bool {
    workspaceTopicGenericWords.contains(normalized)
}

let workspaceTopicFileExtensions: Set<String> = [
    "swift", "pdf", "docx", "doc", "xlsx", "xls", "pptx", "ppt", "key", "numbers", "pages", "txt", "md", "rtf", "png",
    "jpg", "jpeg", "heic", "gif", "mov", "mp4", "mp3", "csv", "json", "toml", "yaml", "yml", "html", "js", "ts", "py",
    "rb", "go", "rs", "c", "h", "m", "mm", "cpp", "xcodeproj", "xcworkspace", "zip", "dmg", "app", "sh", "log", "tex",
]

/// Words that name the kind of thing, not what it's about. Lowercase and NFKC, as normalized.
let workspaceTopicGenericWords: Set<String> = [
    // English
    "work", "working", "file", "files", "document", "documents", "doc", "docs", "page", "web", "website", "site",
    "browser", "window", "windows", "tab", "tabs", "app", "apps", "application", "applications", "program", "software",
    "development", "dev", "project", "projects", "task", "tasks", "topic", "topics", "theme", "course", "note", "notes",
    "new", "untitled", "draft", "home", "homepage", "start", "settings", "preferences", "general", "inbox", "mail",
    "email", "message", "messages", "chat", "downloads", "download", "desktop", "recents", "recent", "favorites",
    "folder", "folders", "misc", "other", "stuff", "view", "edit", "editing", "text", "data", "code", "coding",
    "programming", "python", "javascript", "typescript", "java", "test", "tests", "testing", "build", "debug",
    "terminal", "shell", "zsh", "bash", "fish", "ssh", "git", "review", "update", "meeting", "meetings", "calendar",
    "today", "week", "day", "image", "images", "photo", "photos", "video", "videos", "music", "song", "audio", "search",
    "results", "login", "sign", "account", "dashboard", "overview", "metadata", "title", "info", "information",
    "content", "main", "index", "readme", "list", "table", "sheet", "spreadsheet", "presentation", "slides", "slide",
    "version", "copy", "final", "edited", "the", "and", "for", "with", "from", "this", "that", "your", "about", "into",
    "untitled document", "new tab", "start page", "new window", "new note", "new document", "home page",
    // Chinese
    "工作", "文件", "文档", "网页", "网站", "窗口", "应用", "程序", "软件", "开发", "项目", "任务", "主题", "课程", "笔记",
    "新建", "未命名", "草稿", "初稿", "主页", "首页", "设置", "偏好设置", "通用", "收件箱", "邮件", "消息", "下载", "桌面",
    "最近", "收藏", "文件夹", "其他", "视图", "编辑", "文本", "数据", "代码", "编程", "测试", "构建", "终端", "审查",
    "更新", "会议", "日历", "今天", "图片", "照片", "视频", "音乐", "搜索", "结果", "登录", "账户", "信息", "内容", "列表",
    "表格", "演示", "幻灯片", "版本", "副本", "新标签页", "标签页", "未命名文档", "新建文稿", "文稿",
]
