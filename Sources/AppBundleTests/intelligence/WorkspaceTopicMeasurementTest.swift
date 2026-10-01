@testable import AppBundle
import Common
import XCTest

/// Anonymous, made-up tab titles in a few topics, plus unrelated ones, for measuring at scale.
@MainActor
enum WorkspaceTopicFixtures {
    static let topics: [(app: () -> TestApp, titles: [String])] = [
        ({ TopicTestApps.xcode }, ["Config.swift — tiling-app", "SidebarModel.swift — tiling-app", "Layout.swift — tiling-app"]),
        ({ TopicTestApps.terminal }, ["tiling-app — swift test", "tiling-app — git log", "tiling-app — make build"]),
        ({ TopicTestApps.keynote }, ["ECON 4310 第三讲 需求弹性.key", "ECON 4310 Lecture 5 — Monopoly", "ECON 4310 期中复习.key"]),
        ({ TopicTestApps.numbers }, ["ECON 4310 期中成绩.numbers", "Kyoto trip budget.numbers", "2027 季度预算.numbers"]),
        ({ TopicTestApps.mail }, ["Re: ECON 4310 office hours", "Re: Kyoto hotel booking", "季度预算汇报 — 会议安排"]),
    ]
    static let unrelated = ["Wi-Fi", "Piano practice log", "Recipe: miso soup", "Quarterly report draft", "婚礼宾客名单", "Garden plan"]

    /// `count` tabs, one window each, in the focused tab's project.
    static func make(_ count: Int, firstWindowId: UInt32 = 1000) {
        for index in 0 ..< count {
            let workspace = Workspace.get(byName: "fixture-\(index)")
            // As Tabs mode names tabs: generated names aren't labels.
            workspace.markAsAutomaticallyNamed()
            let (app, title): (TestApp, String)
            if index % 4 == 3 {
                (app, title) = (TopicTestApps.mail, unrelated[index % unrelated.count] + " #\(index)")
            } else {
                let topic = topics[index % topics.count]
                (app, title) = (topic.app(), topic.titles[(index / topics.count) % topic.titles.count])
            }
            TestWindow.new(id: firstWindowId + UInt32(index), parent: workspace.rootTilingContainer, app: app, title: title)
        }
    }
}

/// How much main-actor work a suggestion adds, and the policy's cost, at 10, 30 and 100 tabs.
/// Model latency is measured separately, on a real model, by WorkspaceTopicModelEvaluationTest.
@MainActor
final class WorkspaceTopicMeasurementTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TopicTestApps.reset()
        _ = WorkspaceTopicTestEnvironment.setUp(provider: FakeWorkspaceTopicProvider())
    }

    override func tearDown() async throws {
        WorkspaceTopicTestEnvironment.tearDown()
        TopicTestApps.reset()
        try await super.tearDown()
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    func testMainActorSnapshotAndPolicyCost() async throws {
        var report: [String] = []
        for count in [10, 30, 100] {
            setUpWorkspacesForTests()
            TopicTestApps.reset()
            _ = WorkspaceTopicTestEnvironment.setUp(provider: FakeWorkspaceTopicProvider())
            WorkspaceTopicFixtures.make(count)
            await updateWorkspaceSidebarModel()
            let snapshot = WorkspaceTopicTestEnvironment.snapshot
            let scope = WorkspaceTopicTestEnvironment.scope()
            var prepared: WorkspaceTopicPreparedRequest?
            let prepareTimes = (0 ..< 25).map { _ in milliseconds { prepared = prepareWorkspaceTopicRequest(scope: scope, snapshot: snapshot) } }
            let candidates = try XCTUnwrap(prepared).candidates
            let items = candidates.map { evidence in
                WorkspaceTopicPolicyItem(evidence: evidence, tags: evidence.windows.first.map { title in
                    title.title.contains("ECON") ? ["ECON 4310"] : title.title.contains("tiling-app") ? ["tiling-app"] :
                        title.title.contains("Kyoto") ? ["Kyoto"] : []
                } ?? [])
            }
            var groups: [WorkspaceTopicSuggestedGroup] = []
            let policyTimes = (0 ..< 5).map { _ in milliseconds { groups = WorkspaceTopicPolicy.groups(for: items) } }
            let thinTimes = (0 ..< 5).map { _ in milliseconds { _ = candidates.filter(workspaceTopicHasEnoughEvidence) } }
            report.append(String(format: "n=%d candidates=%d prepare(main) p50=%.2fms p95=%.2fms policy(off-main) p50=%.1fms thin(off-main) p50=%.1fms groups=%d",
                count, candidates.count, percentile(prepareTimes, 0.5), percentile(prepareTimes, 0.95), percentile(policyTimes, 0.5),
                percentile(thinTimes, 0.5), groups.count))
            XCTAssertEqual(candidates.count, min(count, workspaceTopicMaximumCandidates))
            // A loose bound: the target is under 5 ms at P95; the report gives the real number.
            XCTAssertLessThan(percentile(prepareTimes, 0.95), 50, "Main-actor snapshot at \(count) tabs")
        }
        print("TOPIC-MEASURE\n" + report.joined(separator: "\n"))
    }
}
