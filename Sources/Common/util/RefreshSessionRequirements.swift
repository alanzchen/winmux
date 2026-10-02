/// Why hidden windows must be re-parked even though WinMux believes they are in place.
public enum HiddenWindowsReassertion: Sendable, Equatable, CustomStringConvertible {
    /// Wake and startup: windows may have moved with no AX events.
    case always
    /// A display change settled. Applies only while the display topology is still at this
    /// generation: a newer change gets its own settled refresh.
    case displayTopology(generation: UInt64)

    public func union(_ other: HiddenWindowsReassertion?) -> HiddenWindowsReassertion {
        switch (self, other) {
            case (.always, _), (_, .always): .always
            case (.displayTopology(let a), .displayTopology(let b)): .displayTopology(generation: max(a, b))
            case (.displayTopology, nil): self
        }
    }

    public func applies(atTopologyGeneration current: UInt64) -> Bool {
        switch self {
            case .always: true
            case .displayTopology(let generation): generation == current
        }
    }

    public var description: String {
        switch self {
            case .always: "always"
            case .displayTopology(let generation): "displayTopology(\(generation))"
        }
    }
}

/// What a refresh session must do. A session that runs on behalf of several coalesced events
/// does what each of them needs: the union, never just the requirements of one of them.
public struct RefreshSessionRequirements: Sendable, Equatable, CustomStringConvertible {
    public var windowRefreshBarrier: Bool
    public var layoutReasonNormalization: Bool
    /// Window frames must be re-sent even where the last applied layout matches.
    public var freshWindowFrames: Bool
    public var hiddenWindowsReassertion: HiddenWindowsReassertion?

    public init(
        windowRefreshBarrier: Bool,
        layoutReasonNormalization: Bool,
        freshWindowFrames: Bool,
        hiddenWindowsReassertion: HiddenWindowsReassertion?,
    ) {
        self.windowRefreshBarrier = windowRefreshBarrier
        self.layoutReasonNormalization = layoutReasonNormalization
        self.freshWindowFrames = freshWindowFrames
        self.hiddenWindowsReassertion = hiddenWindowsReassertion
    }

    public var canReuseLastAppliedWindowFrames: Bool { !freshWindowFrames }

    public func union(_ other: RefreshSessionRequirements) -> RefreshSessionRequirements {
        RefreshSessionRequirements(
            windowRefreshBarrier: windowRefreshBarrier || other.windowRefreshBarrier,
            layoutReasonNormalization: layoutReasonNormalization || other.layoutReasonNormalization,
            freshWindowFrames: freshWindowFrames || other.freshWindowFrames,
            hiddenWindowsReassertion: hiddenWindowsReassertion.map { $0.union(other.hiddenWindowsReassertion) }
                ?? other.hiddenWindowsReassertion,
        )
    }

    public var description: String {
        "barrier=\(windowRefreshBarrier) normalization=\(layoutReasonNormalization) " +
            "freshFrames=\(freshWindowFrames) reassert=\(hiddenWindowsReassertion?.description ?? "nil")"
    }
}
