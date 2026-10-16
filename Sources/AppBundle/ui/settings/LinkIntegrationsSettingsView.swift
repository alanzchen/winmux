import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Settings → Integrations: the user's Hookmark-compatible integrations, added by pasting an app's scripts or
// imported from a file of Hookmark integration records. Nothing runs here: what's added is off until the
// user turns it on, having read what it is, where it came from and what it may do.

struct LinkIntegrationsSettingsView: View {
    @ObservedObject var store: LinkIntegrationStore
    @State private var draft: LinkIntegrationDraft?
    @State private var review: LinkIntegrationImportReview?
    @State private var turningOn: LinkIntegration?
    @State private var removing: LinkIntegration?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("An integration is one app's scripts, as Hookmark has them. Its Get Address script takes a link to what "
                    + "that app's window shows, when you choose Pin with Integration in a tab's menu; its Open Item script "
                    + "opens such a link again when you click the pin.")
                    .fixedSize(horizontal: false, vertical: true)
                Label {
                    Text("Integrations are scripts that run as you, with WinMux's permissions: they can control apps, press keys, "
                        + "use the clipboard and run shell commands. WinMux ships none, downloads none, and runs one only when "
                        + "you choose it in a tab's menu or click a link it took. Each stays off until you turn it on. Only add "
                        + "scripts from a source you trust.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "exclamationmark.shield") }
                    .foregroundStyle(.secondary)
                if let reason = store.readOnlyReason {
                    Label(reason, systemImage: "lock").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Add Integration…") { draft = LinkIntegrationDraft() }
                    Button("Import Hookmark Scripts…") { chooseImportFile() }
                }
                .disabled(store.readOnlyReason != nil)
                if store.integrations.isEmpty {
                    Text("No integrations.").foregroundStyle(.secondary)
                }
                ForEach(store.integrations) { integration in
                    LinkIntegrationRow(integration: integration, readOnly: store.readOnlyReason != nil,
                        setOn: { on in
                            if on { turningOn = integration } else { perform { try store.setEnabled(id: integration.id, false) } }
                        },
                        edit: { draft = LinkIntegrationDraft(integration) },
                        remove: { removing = integration })
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $draft) { draft in
            LinkIntegrationEditor(draft: draft, save: save, cancel: { self.draft = nil })
        }
        .sheet(item: $review) { review in
            LinkIntegrationImportSheet(review: review, add: { chosen in
                self.review = nil
                perform { try store.add(chosen) }
            }, cancel: { self.review = nil })
        }
        .alert("Turn on the \(turningOn?.appName ?? "") integration?", isPresented: Binding(
            get: { turningOn != nil }, set: { if !$0 { turningOn = nil } }), presenting: turningOn
        ) { integration in
            Button("Cancel", role: .cancel) { turningOn = nil }
            Button("Turn On") {
                turningOn = nil
                perform { try store.setEnabled(id: integration.id, true, trustingDigest: integration.digest) }
            }
        } message: { integration in
            Text(linkIntegrationTrustMessage(integration))
        }
        .alert("Remove the \(removing?.appName ?? "") integration?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing
        ) { integration in
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                removing = nil
                perform { try store.remove(id: integration.id) }
            }
        } message: { _ in
            Text("Pins it took keep their links, but it won't open them: clicked, they say why. Adding it again doesn't bring "
                + "them back to it; Update from Window does.")
        }
        .alert("Integrations", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func perform(_ change: () throws -> Void) {
        do { try change() } catch { problem = error.localizedDescription }
    }

    /// Adds or saves the draft; what's wrong with it, if anything.
    private func save(_ draft: LinkIntegrationDraft) -> String? {
        do {
            var integration = try makePastedLinkIntegration(bundleId: draft.bundleId, appName: draft.appName,
                getAddress: draft.getAddress, getName: draft.getName, openItem: draft.openItem, newItem: draft.newItem,
                scheme: draft.scheme)
            if let editing = draft.editing {
                integration.id = editing.id
                integration.source = editing.source
                integration.addedAt = editing.addedAt
                integration.editedAt = editing.editedAt
                integration.scriptingMethod = editing.scriptingMethod
                integration.urlConverter = editing.urlConverter
                try store.update(integration)
            } else {
                try store.add([integration])
            }
            self.draft = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Hookmark Scripts"
        panel.message = "Choose a property list of Hookmark integration records. Nothing in it runs: you choose what to add, "
            + "and what you add stays off until you turn it on."
        panel.prompt = "Read"
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    private func importFile(_ url: URL) {
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= linkIntegrationImportFileLimit else {
                throw LinkIntegrationError.invalid("“\(url.lastPathComponent)” is larger than an integrations file WinMux reads (4 MB).")
            }
            let found = try importHookmarkIntegrations(try Data(contentsOf: url), fileName: url.lastPathComponent,
                existingBundleIds: Set(store.integrations.map(\.bundleId)))
            review = LinkIntegrationImportReview(fileName: url.lastPathComponent, found: found)
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// What the user reads before turning an integration on.
func linkIntegrationTrustMessage(_ integration: LinkIntegration) -> String {
    let analysis = integration.analysis
    var lines = ["Its scripts will run as you, with WinMux's permissions, whenever you choose Pin with \(integration.appName) "
        + "Integration in a tab's menu, or click a link it took. WinMux doesn't check what they do.",
                 "Where it came from: \(integration.source.label)\(integration.editedAt == nil ? "" : ", then edited here")."]
    lines += analysis.notes.map { "• " + $0 }
    lines += analysis.problems.map { "• " + $0 }
    return lines.joined(separator: "\n\n")
}

// MARK: - A row

private struct LinkIntegrationRow: View {
    let integration: LinkIntegration
    let readOnly: Bool
    let setOn: (Bool) -> Void
    let edit: () -> Void
    let remove: () -> Void
    @State private var showsScripts = false

    var body: some View {
        let analysis = integration.analysis
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(integration.appName).font(.headline)
                        Text(integration.bundleId).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Toggle("On", isOn: Binding(get: { integration.isActive }, set: { setOn($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("\(integration.appName) integration on")
                        .disabled(readOnly || (!integration.isActive && analysis.verdict == .unsupported))
                }
                LinkIntegrationVerdictLabel(verdict: analysis.verdict)
                Text(integration.source.label + (integration.editedAt == nil ? "" : ", then edited here"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let scheme = integration.scheme {
                    Text("Scheme: \(scheme):").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(analysis.problems, id: \.self) { problem in
                    Label(problem, systemImage: "xmark.octagon").font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(analysis.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Scripts", isExpanded: $showsScripts) {
                    VStack(alignment: .leading, spacing: 10) {
                        LinkIntegrationScriptText(slot: "Get Address", script: integration.getAddress)
                        LinkIntegrationScriptText(slot: "Get Name", script: integration.getName)
                        LinkIntegrationScriptText(slot: "Open Item", script: integration.openItem)
                        LinkIntegrationScriptText(slot: "New Item (kept, not run)", script: integration.newItem)
                    }
                    .padding(.top, 6)
                }
                HStack {
                    Button("Edit…", action: edit)
                    Button("Remove…", role: .destructive, action: remove)
                }
                .controlSize(.small)
                .disabled(readOnly)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(integration.appName) integration")
    }

    private var status: String {
        if integration.isActive { return "On" }
        if integration.isEnabled { return "Off: changed since turned on" }
        return "Off"
    }
}

private struct LinkIntegrationVerdictLabel: View {
    let verdict: LinkIntegrationAnalysis.Verdict

    var body: some View {
        switch verdict {
            case .runsUnchanged: Label(verdict.label, systemImage: "checkmark.circle").foregroundStyle(.green)
            case .runsWithNotes: Label(verdict.label, systemImage: "checkmark.circle.badge.questionmark").foregroundStyle(.green)
            case .needsAdaptation: Label(verdict.label, systemImage: "wrench.and.screwdriver").foregroundStyle(.orange)
            case .unsupported: Label(verdict.label, systemImage: "nosign").foregroundStyle(.red)
        }
    }
}

private struct LinkIntegrationScriptText: View {
    let slot: String
    let script: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(slot).font(.caption.bold())
                if let script { Text(hookmarkScriptLanguage(script).label).font(.caption).foregroundStyle(.secondary) }
            }
            if let script {
                Text(script)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            } else {
                Text("None").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Adding and editing

struct LinkIntegrationDraft: Identifiable {
    let id = UUID()
    var editing: LinkIntegration?
    var bundleId = ""
    var appName = ""
    var getAddress = ""
    var getName = ""
    var openItem = ""
    var newItem = ""
    var scheme = ""

    init() {}

    init(_ integration: LinkIntegration) {
        editing = integration
        bundleId = integration.bundleId
        appName = integration.appName
        getAddress = integration.getAddress
        getName = integration.getName ?? ""
        openItem = integration.openItem ?? ""
        newItem = integration.newItem ?? ""
        scheme = integration.scheme ?? ""
    }
}

private struct LinkIntegrationEditor: View {
    @State var draft: LinkIntegrationDraft
    let save: (LinkIntegrationDraft) -> String?
    let cancel: () -> Void
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.editing == nil ? "Add Integration" : "Edit Integration").font(.headline)
            Text("Paste the app's scripts as Hookmark has them, in AppleScript, or in JavaScript starting with //JavaScript. "
                + "Nothing runs now. " + (draft.editing == nil ? "It's added off." : "Changed scripts turn it off."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose App…") { chooseApp() }
                TextField("Bundle identifier", text: $draft.bundleId).accessibilityLabel("Bundle identifier")
                TextField("App name", text: $draft.appName).accessibilityLabel("App name")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    LinkIntegrationScriptField(title: "Get Address", help: "Required. Returns the address of what's in front: "
                        + "a URL, a file path, or [name](url).", text: $draft.getAddress, height: 140)
                    LinkIntegrationScriptField(title: "Get Name", help: "Optional. Its name, when Get Address gives none.",
                        text: $draft.getName, height: 70)
                    LinkIntegrationScriptField(title: "Open Item", help: "Optional. Opens the address it's given as \"$0\". "
                        + "Without it, macOS opens the link.", text: $draft.openItem, height: 90)
                    LinkIntegrationScriptField(title: "New Item", help: "Optional. Kept as given: WinMux has nothing that runs it.",
                        text: $draft.newItem, height: 50)
                }
            }
            TextField("Scheme of the links Open Item opens (optional), such as x-example", text: $draft.scheme)
                .accessibilityLabel("Scheme")
            if let problem {
                Text(problem).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(draft.editing == nil ? "Add" : "Save") { problem = save(draft) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 660)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose the App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundleId = Bundle(url: url)?.bundleIdentifier else { return }
        draft.bundleId = bundleId
        draft.appName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
    }
}

private struct LinkIntegrationScriptField: View {
    let title: String
    let help: String
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.bold())
                if !text.isEmpty { Text(hookmarkScriptLanguage(text).label).font(.caption).foregroundStyle(.secondary) }
            }
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LinkIntegrationScriptEditor(text: $text, label: "\(title) script")
                .frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
        }
    }
}

/// A plain text view for a script: no smart quotes, dashes or replacements, which would break it.
private struct LinkIntegrationScriptEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = text
        view.delegate = context.coordinator
        view.setAccessibilityLabel(label)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

// MARK: - Importing

struct LinkIntegrationImportReview: Identifiable {
    let id = UUID()
    let fileName: String
    let found: LinkIntegrationImport
}

private struct LinkIntegrationImportSheet: View {
    let review: LinkIntegrationImportReview
    let add: ([LinkIntegration]) -> Void
    let cancel: () -> Void
    @State private var chosen: Set<String>

    init(review: LinkIntegrationImportReview, add: @escaping ([LinkIntegration]) -> Void, cancel: @escaping () -> Void) {
        self.review = review
        self.add = add
        self.cancel = cancel
        _chosen = State(initialValue: Set(review.found.integrations.filter { $0.analysis.verdict != .unsupported }.map(\.id)))
    }

    var body: some View {
        let integrations = review.found.integrations
        VStack(alignment: .leading, spacing: 10) {
            Text("Import from “\(review.fileName)”").font(.headline)
            Text(linkIntegrationImportSummary(review.found))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(integrations) { integration in
                    Toggle(isOn: Binding(get: { chosen.contains(integration.id) },
                                         set: { if $0 { chosen.insert(integration.id) } else { chosen.remove(integration.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(integration.appName) — \(integration.bundleId)")
                            LinkIntegrationVerdictLabel(verdict: integration.analysis.verdict).font(.caption)
                            if let problem = integration.analysis.problems.first {
                                Text(problem).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityLabel("Add \(integration.appName)")
                }
                if !review.found.skipped.isEmpty {
                    Section("Left out") {
                        ForEach(review.found.skipped, id: \.key) { skipped in
                            Text("\(skipped.key): \(skipped.reason)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Add 1 Integration" : "Add \(chosen.count) Integrations") {
                    add(integrations.filter { chosen.contains($0.id) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 520)
    }
}

/// How an import's records fare: the compatibility report the user reads before adding any.
func linkIntegrationImportSummary(_ found: LinkIntegrationImport) -> String {
    var counts: [LinkIntegrationAnalysis.Verdict: Int] = [:]
    for integration in found.integrations { counts[integration.analysis.verdict, default: 0] += 1 }
    let parts: [String] = [LinkIntegrationAnalysis.Verdict.runsUnchanged, .runsWithNotes, .needsAdaptation, .unsupported]
        .compactMap { verdict in counts[verdict].map { "\($0) \(verdict.label.lowercased())" } }
    var text = "\(found.integrations.count) record\(found.integrations.count == 1 ? "" : "s") found"
    if !parts.isEmpty { text += ": " + parts.joined(separator: ", ") }
    if !found.skipped.isEmpty { text += "; \(found.skipped.count) left out" }
    return text + ". Nothing in the file runs now, and what you add stays off until you turn it on."
}
