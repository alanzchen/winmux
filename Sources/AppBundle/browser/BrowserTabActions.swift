import AppKit
import os

/// Why a browser tab action wasn't asked of the browser. Categories only, never a title or address.
enum BrowserTabActionRefusal: String, Error, Sendable {
    /// The tab isn't the one listed any more: closed, moved, or changed since the last read.
    case changed
    /// It's in a Safari topic its tab bar shows closed.
    case collapsedTopic
    /// Its tab bar, or its topic, doesn't account for its tabs as listed.
    case unaccounted
    /// The browser didn't answer in time.
    case noResponse
    /// The tab doesn't offer the action.
    case noAction
    /// Out of view, and scrolling didn't bring it into view.
    case outOfView
    /// A later action, or WinMux, called it off.
    case cancelled
}

/// The kind of error an Accessibility action call answered.
enum BrowserTabAXFailure: String, Sendable {
    case timedOut
    case invalidElement
    case unsupported
    case other

    init(_ error: AXError) {
        switch error {
            case .cannotComplete: self = .timedOut
            case .invalidUIElement: self = .invalidElement
            case .actionUnsupported, .attributeUnsupported: self = .unsupported
            default: self = .other
        }
    }
}

/// What calling an Accessibility action did: whether it was called at all, and what it answered.
enum BrowserTabAXCall: Equatable, Sendable {
    /// Not called: the element doesn't offer it, or its actions couldn't be read.
    case unavailable
    case failed(BrowserTabAXFailure)
    case succeeded
}

/// Whether a dispatched action was then seen done: a select's tab selected, a close's tab gone.
enum BrowserTabActionPostcondition: String, Sendable {
    case confirmed
    case unknown
}

/// What selecting or closing a browser tab did.
enum BrowserTabActionResult: Equatable, Sendable {
    /// Nothing was asked of the browser.
    case notDispatched(BrowserTabActionRefusal)
    /// The browser was asked and said it did it; `confirmed` once that was seen.
    case dispatched(BrowserTabActionPostcondition)
    /// The browser was asked and answered with an error, and it wasn't seen done.
    case failed(BrowserTabAXFailure)

    /// Whether the browser was asked, whatever it answered: only a result never sent is not.
    var isDispatched: Bool { if case .notDispatched = self { false } else { true } }

    var logName: String {
        switch self {
            case .notDispatched(let refusal): "notDispatched.\(refusal.rawValue)"
            case .dispatched(let postcondition): "dispatched.\(postcondition.rawValue)"
            case .failed(let failure): "failed.\(failure.rawValue)"
        }
    }
}

enum BrowserTabActionKind: String, Sendable {
    case select
    case close
}

/// How long, after an action was dispatched, its tab is read again for its effect: at once, then
/// after each of these pauses, all within `browserTabActionConfirmationBudget`, reads included.
let browserTabActionConfirmationPauses: [TimeInterval] = [0.03, 0.07, 0.15]
let browserTabActionConfirmationBudget: TimeInterval = 0.25

/// One action's path, for the debug log: categories and timings only, never a title or address.
struct BrowserTabActionTrace {
    let kind: BrowserTabActionKind
    var stage = "check"
    var tabClass = "unread"
    var link = "unread"
    var call: BrowserTabAXCall? = nil
    var dispatchAttempted = false
    var postcondition: BrowserTabActionPostcondition? = nil

    mutating func describe<Node>(_ record: BrowserTabAXRecord<Node>, tabClass: String) {
        self.tabClass = tabClass
        link = switch record.parent {
            case .element: "parent"
            case .none: "noParent"
            case .unreadable: "unreadable"
        }
    }

    func line(_ result: BrowserTabActionResult, elapsed: TimeInterval) -> String {
        let ax = switch call {
            case nil: "none"
            case .unavailable?: "unavailable"
            case .succeeded?: "succeeded"
            case .failed(let failure)?: failure.rawValue
        }
        return "\(kind.rawValue) result=\(result.logName) stage=\(stage) class=\(tabClass) link=\(link) ax=\(ax) " +
            "dispatchAttempted=\(dispatchAttempted) postcondition=\(postcondition?.rawValue ?? "none") ms=\(Int((elapsed * 1000).rounded()))"
    }
}

/// WinMux's debug log of browser tab actions (`log stream --level debug --predicate 'subsystem == "dev.winmux"'`).
let browserTabActionLog = Logger(subsystem: "dev.winmux", category: "BrowserTabActions")
