import Common
import Foundation
import os

private let persistenceLog = Logger(subsystem: "dev.winmux", category: "Persistence")

/// A file WinMux saves its own state to, in Application Support.
enum PersistedStateFile: String, CaseIterable, Comparable {
    case savedWorkspaces = "saved-workspaces.json"
    case sidebarOrganization = "sidebar-organization.json"
    case auxiliaryWindowLinks = "auxiliary-window-links.json"
    case restartWindowState = "window-state.json"

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// The persistent menu item's title: in Chinese when the user's language is, as for Config Has Errors.
let persistenceFailedMenuTitle = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    ? "无法保存 WinMux 状态" : "Couldn't save WinMux state"

/// The menu action that writes again, now, every file that has changes not saved.
let persistenceRetryNowMenuTitle = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "立即尝试保存" : "Try Saving Now"

/// What follows a failed write of a state file.
enum PersistenceRecovery {
    /// It holds changes not saved, and writing it again saves them: tried again after `retryDelays`, on its next
    /// change, and from the menu.
    case retry(@MainActor () -> Void)
    /// The change was refused and not made: nothing is unsaved. The next change to it writes it again.
    case changeNotMade
    /// Nothing is saved to it this session: where to save couldn't be found, or WinMux was quitting.
    case notSaved
}

/// The one owner of whether WinMux's state files are saved. Their writes report here how they went. A failure is
/// logged and keeps a menu item, whose details say what happens next for each file, until that file is written.
@MainActor
final class PersistenceHealth {
    static let shared = PersistenceHealth()
    /// After the first failure, then after each failed retry. Bounded: the last is the last retry.
    static let retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120), .seconds(600)]

    struct Failure {
        let error: String
        let at: Date
        /// Failed writes in a row.
        let attempts: Int
        let recovery: PersistenceRecovery
        /// When the next retry runs; nil when none is scheduled.
        var retryAt: Date?
    }

    private(set) var failures: [PersistedStateFile: Failure] = [:]
    private var retries: [PersistedStateFile: Task<Void, Never>] = [:]
    /// Runs `retry` after `delay`. Replaceable for tests.
    var startRetry: (Duration, @escaping @MainActor () -> Void) -> Task<Void, Never> = PersistenceHealth.sleepThenRetry
    var now: () -> Date = Date.init

    private nonisolated static func sleepThenRetry(_ delay: Duration, _ retry: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            retry()
        }
    }

    func recordFailure(_ file: PersistedStateFile, _ error: any Error, _ recovery: PersistenceRecovery) {
        let attempts = (failures[file]?.attempts ?? 0) + 1
        var failure = Failure(error: error.localizedDescription, at: now(), attempts: attempts, recovery: recovery)
        persistenceLog.error("Couldn't save \(file.rawValue, privacy: .public) (failure \(attempts)): \(String(describing: error), privacy: .public)")
        retries[file]?.cancel()
        retries[file] = nil
        if case .retry(let retry) = recovery, attempts <= Self.retryDelays.count {
            let delay = Self.retryDelays[attempts - 1]
            failure.retryAt = failure.at.addingTimeInterval(TimeInterval(delay.components.seconds))
            retries[file] = startRetry(delay) { [weak self] in
                self?.retries[file] = nil
                self?.failures[file]?.retryAt = nil
                retry()
            }
        }
        failures[file] = failure
        publish()
    }

    func recordSuccess(_ file: PersistedStateFile) {
        retries[file]?.cancel()
        retries[file] = nil
        guard let failure = failures.removeValue(forKey: file) else { return }
        persistenceLog.notice("Saved \(file.rawValue, privacy: .public) after \(failure.attempts) failed write(s)")
        publish()
    }

    /// Whether any file holds changes that writing again could save.
    var canRetryNow: Bool {
        failures.values.contains { if case .retry = $0.recovery { true } else { false } }
    }

    /// Writes again, now, every file that holds changes not saved. Each reports how it went.
    func retryNow() {
        for (file, failure) in failures.sorted(by: { $0.key < $1.key }) {
            guard case .retry(let retry) = failure.recovery else { continue }
            retries[file]?.cancel()
            retries[file] = nil
            failures[file]?.retryAt = nil
            retry()
        }
        publish()
    }

    /// The details the menu item opens; nil while every file is saved.
    var details: Message? {
        guard !failures.isEmpty else { return nil }
        let lines = failures.sorted { $0.key < $1.key }.map { file, failure in
            "\(file.rawValue): \(failure.error) \(failure.attempts) failed write(s), the last at "
                + "\(Self.time(failure.at)). \(status(failure))"
        }
        var body = lines.joined(separator: "\n")
        if canRetryNow { body += "\n\nChanges not saved are lost if WinMux quits before a write succeeds." }
        return Message(description: persistenceFailedMenuTitle, body: body)
    }

    private func status(_ failure: Failure) -> String {
        switch failure.recovery {
            case .retry:
                if let retryAt = failure.retryAt { return "Trying again at \(Self.time(retryAt))." }
                return "Will try again on its next change, or with \(persistenceRetryNowMenuTitle)."
            case .changeNotMade: return "The change wasn't made. Its next change tries again."
            case .notSaved: return "Not saved this session."
        }
    }

    private static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }

    private func publish() {
        TrayMenuModel.shared.persistenceFailureDetails = details
        TrayMenuModel.shared.canRetryPersistenceNow = canRetryNow
    }

    func resetForTests() {
        for task in retries.values { task.cancel() }
        retries = [:]
        failures = [:]
        startRetry = PersistenceHealth.sleepThenRetry
        now = Date.init
        publish()
    }
}
