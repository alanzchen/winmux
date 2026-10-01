<!--
  Implementation status, added with the P0 + P1 implementation (2026-10-01). The plan below
  is Alan's text, unchanged. Its own header ("尚未实现") and its baseline describe when it was
  written; this block says what has been built since.
-->

> **实施状态（2026-10-01，P0 + P1 已实现；P2、P3 仍为建议）**
>
> 本计划的阅读基线是 `ee150c27`，是历史参考，不是回退目标。实现基于 `bb4e36e8`（origin/main），并按当时的源码与 MacOSX27.0 SDK 逐项核对。
>
> | 章节 | 状态 |
> |---|---|
> | §1 核心决定 | 已实现（P1）：AI 只组织侧边栏 Collections，不拆 split、不移动窗口、不改焦点、不取消固定。 |
> | §2 代码现状 | 已按 `bb4e36e8` 重新核对；Tabs 模式下面板始终显示本显示器的当前项目（Other Projects 只在 Sidebar 模式出现）。 |
> | §3 Apple API | 已实现，**与原计划有一处不同**：P0 在真实设备上比较后，默认使用 `SystemLanguageModel.default`（通用模型，每个 tab 单独会话、只产标签），`.contentTagging` 保留为可选变体。原因见下。availability 隔离，macOS 13 部署目标不变，FoundationModels 为弱链接。 |
> | §4.1 第一版 | 已实现：设置开关（默认关闭）、Tabs 项目菜单与多选菜单入口“Suggest Topic Groups…”、预览（可改名、取消成员／整组）、一次应用、一次撤销。只读模式下可预览，不能应用。 |
> | §4.2 第二版 | 建议，未实现（P2）。 |
> | §4.3 | 已遵守。 |
> | §5 数据与隐私 | 已实现 5.1、5.2、5.4，以及 5.3 的第 1、2 条（只限浏览器窗口标题，按次授权，绑定所展示的原文与窗口；浏览器内部标签页从不读取）。5.3 的第 3、4 条（provenance、缓存新鲜度）为 P3 建议，未实现。 |
> | §6 推理与分组 | 已实现；阈值来自 P0 匿名样例，属策略分数，未作校准。6.4 的预算目前用保守字符上限，未调用 `tokenCount(for:)`。 |
> | §7 异步执行 | 按需路径已实现（单飞、取消、代次、实际占用跟踪、有界内存 LRU）；后台调度（防抖、重算间隔）为 P2 建议。 |
> | §8 接受与撤销 | 已实现：会话内整批重新验证；先写身份并检查写入结果，再一次写入 organization；失败时回滚并报告；撤销走仅限 organization 的分支，不重建布局、不改焦点。不声称跨文件原子性。 |
> | §9 文件计划 | 已实现，文件有所合并：`Sources/AppBundle/intelligence/`（类型、Apple provider、policy、snapshot、coordinator、commit）与 `ui/sidebar/WorkspaceSidebarTopicSuggestions.swift`。 |
> | §10 P0 / P1 | 已完成。P2 / P3 未开始。 |
> | §11 验证矩阵 | 见交付说明：逻辑、隐私、身份、生命周期、故障注入与原生渲染已测试；真实 macOS 13 启动、多显示器实机和 Apple Intelligence 关闭／未就绪的实机状态未测试。 |
>
> **P0 结论**（macOS 27.0 26A428，M2 Ultra，AFM 3 Core，匿名合成标题）：`.contentTagging` 不加说明时会给提示框架打标签，并漂移到其他语言（英文标题得到德文、中文标签），不适合跨 tab 匹配与命名；通用模型加简短说明能保持标题语言并原样保留名称与代码（如 “ECON 4310”“平台经济”）。整批分组的基线会误合并同一 App 的不同任务，并把一个 tab 放进两个组，因此被否决。通过实际 provider 与 policy 的端到端评估中，通用模型 8 个样例全部符合预期，`.contentTagging` 有 1 个不符合。单次响应约 0.5–1.3 秒。

---

# WinMux：基于 Apple Intelligence 的主题分组整合计划

> **状态：设计与实施计划，尚未实现。**
>
> 仓库：`alanzchen/winmux`  
> 阅读基线：`main` 的提交 `ee150c27b209460c3da165db4ad91da0a693cae6`  
> 调研日期：2026-09-30（America/Chicago）  
> 建议存放位置：`docs/ai-topic-grouping-plan.md`
>
> 本文依据该提交中实际读取的代码和 Apple 官方开发文档编写。“现有”表示已核对代码；“新增／建议”表示待实现设计。没有修改仓库、执行构建或测试，也没有进行原生 macOS 模型实测。实施前应检查工作分支与此提交的差异，而不是强行回退到该提交。

## 1. 核心决定

**将 Safari 式的自动主题组织，接到 WinMux 已有的 `WorkspaceTabCollection` 上；不让 AI 直接操作窗口平铺树。**

WinMux 已经有合适的组织单元：Tabs 模式中的一个 workspace tab 可以承载一个真实窗口，也可以承载多个窗口组成的 split；`WorkspaceTabCollection` 负责把这些 workspace tabs 放在同一个侧边栏分组内，不拥有窗口，也不参与平铺布局。[R1][R2]

建议的体验是：

```text
用户选择当前项目中的若干 workspace tabs
                 ↓
读取已有窗口标题和获准使用的缓存元数据
                 ↓
Apple 本地模型提取主题标签
                 ↓
WinMux 的确定性规则构造、验证分组建议
                 ↓
预览：“WinMux 开发”“文献阅读”“课程准备”
                 ↓
用户接受 → 创建现有侧边栏 Collections → 一次 Undo
```

第一版交付 **按需建议、预览、接受、撤销**。之后再增加后台建议与可选的自动视图组织。以下边界从第一版开始固定：

- **用户手动分组、固定标签和项目划分优先。** 不默认接管已有分组，不自动取消固定。
- **不改变真实窗口布局。** 不拆 split，不移动窗口到其他 workspace，不切项目或显示器，不关闭窗口。
- **模型只提供语义，不获得操作工具。** 它不能运行 CLI、AppleScript、AX 操作或任意回调。
- **设备端优先且本计划只实现设备端。** 不因模型不可用而静默改用云服务。

这些是本计划的产品选择，不是声称 Apple 或现有 WinMux 已实现了相同策略。

## 2. 代码现状与接入依据

### 2.1 必须区分三个不同的“tab/group”

| 概念 | 当前代码中的位置 | 本次如何使用 |
|---|---|---|
| 真实窗口及平铺关系 | `Window`、`Workspace`、`TreeNode` 等 | 只读取元数据；不让模型修改布局关系 |
| 浏览器内部标签 | `BrowserTab` / `BrowserWindowTabs` | 可选的语义证据；不能充当 workspace 或布局节点 |
| 侧边栏组织分组 | `WorkspaceTabCollection` | 本次 AI 主题分组的落点，成员为 `workspaceNames` |

`BrowserTabTarget` 自身的注释也明确限定：它是会话范围的引用，不代表 macOS 窗口或布局节点。[R1][R5]

因此，第一版不是把一个包含 20 个 Safari 页面的大窗口拆成 20 个 WinMux workspace，也不是把主题相近的两个真实窗口合并成同一个 split。它组织的是**现有 workspace tabs**。一个 workspace 内部若同时存在多个不相关任务，可以保持未分组。

### 2.2 已核对的主要模块

| 已读取文件 | 已存在的行为 | 建议接入方式 |
|---|---|---|
| `tree/WorkspaceTabCollections.swift` | Collection、单文件原子写入、同项目分配、持久身份保存、分组投影 | 复用存储与呈现语义；新增批量接受入口，不建第二套永久分组库 |
| `ui/sidebar/WorkspaceSidebarOrganizationActions.swift` | 组织操作进入 sidebar session，并设置 Undo 标题 | AI 接受作为一个新的批量组织操作进入同一路径 |
| `ui/sidebar/WorkspaceSidebarTabUndo.swift` | 保存编辑前后快照；后续结构修改会使旧 Undo 失效 | 一次接受对应一次 Undo；推理和预览不得污染该历史 |
| `ui/sidebar/WorkspaceSidebarSnapshotBuilder.swift` | 将 store 的 `tabCollections` 放入 UI 配置 | 正式分组继续走此入口；后续自动模式另加只读投影 |
| `ui/sidebar/WorkspaceSidebarModel.swift`、`WorkspaceSidebarModelStateApplier.swift` | 构建和发布侧边栏状态，按需刷新界面 | 只挂轻量快照提交／失效信号，不在这里等待模型 |
| `ui/sidebar/WorkspaceSidebarWorkspaceSnapshotBuilder.swift`、`WorkspaceSidebarWindowItemBuilder.swift` | 已有项目、显示器、窗口标题、应用信息和侧边栏可见性处理 | 从完成构建的快照中提取语义输入，不增加一轮 AX 扫描 |
| `browser/BrowserTabsModel.swift`、`BrowserTabs.swift` | AX 读取调度、浏览器缓存、Safari 扩展关联、原生标签选择与关闭 | 复用缓存；AI 不调用选择／关闭动作，不扩大读取范围 |
| `config/Config.swift`、`parseWorkspaceSidebar.swift` | `.tabs` 模式、`config.usesBrowserTabs`、TOML 字段解析 | 将智能分组设置加入现有配置链路 |
| `Sources/AppBundleTests/ui/WorkspaceSidebarNarrowWidthTest.swift` | Tabs 宽度 160、180、200、240、320 的原生布局测试 | 在同一测试模式下覆盖智能分组入口和预览 |

上述前八行的路径相对 `Sources/AppBundle/`。具体源文件链接见 [R1]–[R14]、[R17]。

### 2.3 四个会直接影响实施的现有约束

**分组会取消固定。** 当前 store 的 `create` 和 `assign` 会对被分组的 workspace 调用 `setFavorite(false)`。不能把 AI 结果不加筛选地传进去，否则会悄悄改变用户的 pins。第一版把 pinned workspace 排除在候选之外。[R1]

**持久成员目前以名字保存。** `WorkspaceTabCollection.workspaceNames` 是名字列表；实时 `Workspace.id` 在实例创建时分配。不能因为 `WorkspaceId` 可编码，就假设它可跨重启恢复。第一版运行期用身份校验，提交时才解析为当前名字，并沿用 `saveWorkspaceSidebarIdentities` 的持久身份机制。[R1][R3]

**浏览器缓存不等于浏览历史，也不保证最新。** 现有模型只读取侧边栏正在观察的窗口；隐藏面板保留缓存但不继续做浏览器工作。`BrowserTabSnapshotCache.maximumAge = 10` 是持续读取失败后的宽限逻辑，并非所有缓存都在 10 秒后过期。AI 若使用缓存，必须检查真实的最后观察时间，不能只判断字典中是否存在记录。[R4][R5]

**Collection 操作目前限制在 Tabs 模式。** 相关 action 检查 `config.usesBrowserTabs`，其条件是 sidebar 已启用且模式为 `.tabs`。第一版保留该限制；不要为了显示新功能而自动把用户的 Dock 或 Sidebar 切换为 Tabs。[R2][R6]

## 3. Apple API：使用什么，以及不依赖什么

### 3.1 明确选择 `SystemLanguageModel`

使用系统 `FoundationModels` 框架中的 `SystemLanguageModel`。Apple 将它定义为设备端模型；`default` 对应通用文本任务，`.contentTagging` 对应标签提取。框架现在也有其他模型接入方式，但本计划不采用 Private Cloud Compute 或第三方云模型。[A1][A2]

**不依赖 Safari 私有自动分组引擎。** 本计划无需知道 Safari 内部用了哪一个 adapter，也不依赖能够读取、创建或修改 Safari 原生 AI Topics 的 API。即使 Safari 的相关接口未来变化，WinMux 自己的组织层也可以独立运行。

### 3.2 收紧上一轮讨论中的 API 用法

`.contentTagging` 是专门产生标签的模型用例，不是通用的“输入所有窗口，返回任意复杂分组图”的服务。Apple 的 API 文档明确说明这一用例始终返回标签。WWDC 示例中的 `@Generable` 结构也是主题／动作等标签数组。[A2][A3]

因此推荐分工如下：

| 工作 | 执行者 |
|---|---|
| 从一个 workspace 的有限元数据提取主题 | `.contentTagging` |
| 保存输入与输出的对应关系 | WinMux，不让模型生成真实窗口 ID |
| 选择候选、应用排除规则、聚类、消歧 | 可单测的 Swift policy |
| 验证成员是否仍存在、仍同项目、未被手动改动 | MainActor 上的提交校验 |
| 创建侧边栏分组 | 现有组织操作路径 |
| 可选的短标题润色／跨语言标签归一 | 后续评估后才启用 `SystemLanguageModel.default` |

下面只是 **provider 内部的 API 形状示意**，不是声称已在本仓库编译通过的完整实现：

```swift
// 置于带 macOS 26+ availability guard 的 provider 文件中。
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct WorkspaceTopicTags {
    @Guide(.maximumCount(4))
    var topics: [String]
}

// 调用前检查 model.availability；错误由 provider 转为应用自己的状态。
let model = SystemLanguageModel(useCase: .contentTagging)
let session = LanguageModelSession(model: model)
let response = try await session.respond(
    to: sanitizedWorkspaceEvidence,
    generating: WorkspaceTopicTags.self
)
let tags = response.content.topics
```

每个独立 workspace 的标签请求使用独立会话，避免无关项目的上下文在同一个 transcript 中累积。`LanguageModelSession` 会保留请求之间的状态，因此这是一项有意的隔离选择，不是可以随意省略的优化。[A4]

`@Generable` 帮助约束结构，但不会证明主题判断正确、成员身份有效或用户同意修改。所有操作约束仍由应用代码实施。[A1]

### 3.3 部署与降级

保留整个 App 的 **macOS 13** 最低部署目标和 arm64 分发要求。仓库的 `Package.swift` 最低 Swift tools 版本是 6.2；`AGENTS.md` 则要求开发使用 Xcode 27 / Swift 6.4.0。两者分别是包格式最低要求和项目开发工具链，不要混为一谈。[R15][R16]

实现时，将新模型符号封装在受 `@available(macOS 26.0, *)` 保护的 provider 中，必要时结合 `#if canImport(FoundationModels)`。工厂、UI 和公共 DTO 不应迫使旧系统加载新类型。**可编译不等于旧系统可启动**：弱链接／加载行为必须在旧版本 macOS 上验证。

不可用状态应区分“系统不支持”“设备或地区不支持”“Apple Intelligence 未开启”“模型未就绪”“语言不支持”和暂时性生成失败；具体 SDK 错误由 provider 归一化，业务层不直接绑定某一版 Foundation Models 错误枚举。[A5]

Apple 会随系统更新更换模型，当前文档列出 26.0–26.3、26.4、27.0 对应的模型变化；26.4 与 27 的 API／错误处理也有更新。测试和缓存需要记录 OS build、provider/prompt 版本，不能把旧模型效果当成新版本保证。[A5][A6]

## 4. 产品范围与用户流程

### 4.1 第一版：按需智能分组

入口位于 Tabs 模式的项目菜单或多选菜单：**“建议主题分组…”**。不新增常驻聊天面板，不占用窄侧边栏的一整行工具栏。

流程：用户首次同意在设备端分析所选窗口元数据；选择范围；生成；预览；接受或取消。

默认范围是**当前正在浏览的项目、当前面板显示范围内、未固定且未加入手动 Collection 的 workspace tabs**。这里是浏览中的项目，不应直接拿全局当前焦点项目代替；用户可能正在查看 Other Projects。多选触发时，以所选集合为范围，并要求同一项目。

预览示意，内容为假设示例，并非用户真实窗口：

```text
建议分组 · 当前项目 · 本显示器

[✓] WinMux 开发
    Xcode — WorkspaceSidebarModel.swift
    Terminal — winmux

[✓] 文献阅读
    Preview — Platform competition.pdf
    Obsidian — Literature notes

保持原样：3 个 tabs
分析不足／排除：2 个 tabs

[取消]                 [应用 2 个分组]
```

预览允许修改分组名、取消某个成员／整个分组；修改后少于两个成员的建议不提交。解释来自可展示的共同证据，例如共同出现的项目词，不展示模型虚构的分析过程或“97% 置信度”。

取消和仅预览必须零持久化、零布局修改。应用后建议转成普通的手动 Collection，保留正常的重命名、拖动和撤销能力。

### 4.2 第二版：后台建议与自动组织视图

后续增加两种显式开启的模式：

| 模式 | 推理何时发生 | 是否改永久分组 |
|---|---|---|
| 关闭 | 不发生 | 否 |
| 按需（第一版） | 用户点击 | 仅接受时 |
| 显示建议（后续） | 语义输入稳定后低频执行 | 仅接受时 |
| 自动组织视图（后续） | 同上 | 否；默认使用临时投影，用户可“保留为分组” |

自动模式中的临时组不是另一套可恢复工作区。关闭自动模式时移除投影，返回手动组织；不关闭标签、不移动真实窗口、不删除手动组。

自动组的身份和名称需要稳定：沿用匹配到的旧组 ID／名称，不随每次标题变化重新命名；新结果在拖动、多选、重命名、搜索或其他交互期间暂存，不让鼠标下方的行突然跳动。首次应用布局变化也应等交互结束。所有自动组都提供“保留”“不再建议这些成员组合”“关闭自动组织”。

### 4.3 明确不属于第一版

不做 Safari 原生 Topics 控制、浏览器 tab 拆窗／重排、跨项目搬窗、自动创建 Project、修改 split、自动关闭重复窗口、历史浏览行为画像、屏幕截图／OCR、网页正文读取，以及远程模型或通用 Agent。

这些功能有不同的权限、身份和副作用边界；不能借主题分组入口顺带实现。

## 5. 数据输入、身份和隐私边界

### 5.1 使用已构建的快照

主输入来自已完成构建的 sidebar workspace/window view models，并配合 MainActor 上的实时身份映射。已有 builder 提供应用名、bundle ID、窗口标题和显示范围；优先复用这些信息，不在 SwiftUI `body`、布局回调或 AI actor 中再调用 AX。[R7][R8]

建议新增值类型：

```text
WorkspaceSemanticSnapshot
  requestID / runtimeSessionID
  projectID + selectedScope
  semanticRevision + organizationRevision + privacyRevision
  items[]
    opaqueItemToken              // 仅供本请求映射，不是可执行句柄
    appNames / appBundleIDs
    userFacingWorkspaceLabel
    sanitizedWindowTitles[]
    approvedBrowserEvidence[]    // 第一版默认空
    evidenceCompleteness
```

`Workspace`、`Window`、`AXUIElement`、`NSRunningApplication` 和 UI view models 本身不跨 actor 传递。提取必要的 `String`、值类型 ID、状态枚举，形成 `Sendable` DTO。

在 MainActor 保存本次请求的 token → 活跃对象身份映射。提交时检查同一个对象仍在 registry 中，并检查当前名字、项目、候选资格和内容指纹。**只使用 `Workspace.existing(byName:)` 或现有 registry 查询，不使用会创建缺失 workspace 的 `Workspace.get(byName:)`。**[R3]

### 5.2 不把 UI 噪声当成语义变化

输入指纹包括获准使用的标题、标签、成员组成、排除设置和请求范围。焦点、hover、音频播放状态、favicon、侧边栏宽度、时钟和当前被选中状态不应触发新推理；浏览器选中页改变但输入的标题集合没有改变，也不应重算。

应用内的文件／网页实际改变，或一个 split 的窗口组成改变，才可能使建议过期。用于展示的 UI 数据仍可继续正常更新，不必为了 AI 冻结整个侧边栏。

### 5.3 浏览器元数据采用分级接入

当前 `BrowserTab` 有 `title`、可选 `host`、图标／音频等字段，`BrowserTabTarget` 有 `pid`、`windowId`、`windowSession` 和 `tabId`。**没有通用的完整页面 URL、正文或 incognito 标记**；`iconOrigin` 也不能当作页面 URL。[R5]

具体方案：

1. **第一版默认不附加浏览器内部 tabs。** 浏览器窗口的原生标题也可能包含敏感内容；默认候选构建对识别出的浏览器窗口不取其页面标题。浏览器识别／排除策略应覆盖已知浏览器及用户手动排除项，而不是仅凭现有 Safari/Chromium adapter 判断所有应用的隐私状态。
2. 用户手动选择浏览器 workspace 后，可在本次预览前明确勾选“本次包含这些浏览器标题”，展示要分析的文本，并说明无法判断无痕状态；此授权不沿用到后台自动分析。数据仍仅送设备端 provider。
3. 后续自动浏览器上下文接入，先增加可信的 privacy/provenance 信息：`knownNormal / knownPrivate / unknown`。默认排除 private 与 unknown；能从扩展准确确认的窗口／标签才允许自动使用。不能用标题字符串猜测 private 状态后宣称有隐私保证。
4. 若接入缓存，在 `BrowserTabsModel` 内部提供窄的只读语义快照接口，连同最后成功观察时间和身份返回。现有 `cache.observed` 是内部字段，需要明确暴露，而不是从 `snapshots` 的更新时间推算。[R4][R5]

对于非标准浏览器或应用内 WebView，也不能承诺自动识别全部私密内容。第一版首次启用时解释数据范围，并提供逐应用排除和“查看本次分析内容”。普通 native 文档标题同样可能敏感。

### 5.4 不收集额外内容

不读取文档正文、剪贴板、文本框、完整文件路径、浏览历史数据库或后台页面，不为 AI 发起 URL 抓取。模型输入中的窗口标题始终是“不可信数据”，不能插入可信 system instructions，也不能成为命令。[A7]

缓存第一版仅在内存，设上限；关闭功能或清除数据会取消任务、清空语义缓存／建议。接受后的分组名和成员按现有用户组织数据保存，不保存原始 prompt 或完整模型 transcript。诊断日志默认只记录数量、耗时和错误类别，不记录标题、域名、标签正文。

“设备端”指此功能的推理与输入处理路径；不等于整个 WinMux 没有网络请求，也不代表系统首次准备模型不需要下载。

## 6. 推理与分组策略

### 6.1 候选过滤先于模型

每个请求只处理同一 project 和明确的显示／选择范围。排除已归入手动组的 workspace、pins、空占位、archived 项、已排除应用，以及元数据不足的项。对多窗口 workspace，若存在被排除或不能授权分析的成员，第一版保守地跳过整个 workspace，避免由其余成员推断敏感主题。

不因 `MacWindow.allWindowsMap` 中还有别的窗口，就将所有项目或显示器的窗口加入本次请求。缺失浏览器证据按缺失处理，不扩大 `BrowserTabsModel.watch` 范围来补齐。

### 6.2 提取标签，然后确定性聚类

每个候选 workspace 生成有限的主题标签；标签返回值与输入的映射由调用方保存。第一版不让模型生成成员 ID，所以“幻觉 ID”无法直接进入执行层。

推荐的 policy：

- 清理并去重标签，统一可安全规范化的大小写和空白；维护小型通用词降权表，如“工作”“网页”“文件”。
- 用有区分度的主题标签和标题关键词构造候选相似度。**同一 App 或同一域名本身不足以分组**，也不要让一个窗口中重复的相似浏览器标题淹没其他证据。
- 窗口较少时可直接计算候选两两匹配。形成组时检查组内一致性，不用简单的传递闭包把“甲像乙、乙像丙”无限合并成一个大组。
- 一个 workspace 最多加入一个新建议组；每组至少两个 workspace。无法确定的留在原处，不强制覆盖所有候选。
- 多窗口 split 保留为原子单元。其证据明显混合时宁可不分，不选择一个看似最高分的主题强行覆盖。

阈值应由 P0 的匿名样例集决定。任何内部相似度都叫“策略分数”，不包装成经过校准的概率。中文、英文和中英混合标题必须单独评估；不能假定英文标签自然解决所有跨语言归一问题。

### 6.3 通用模型作为可比较的备选，不预先堆叠模型

P0 同时验证一个简化基线：`SystemLanguageModel.default` 对小批元数据做受约束建议。只有在质量或延迟明显优于标签方案时才调整 provider 选择；提交校验和 UI 设计不变。

若标签质量不足，可以在相同 `WorkspaceTopicProvider` 合约下更换为通用模型提取标签，或增加可选命名步骤。不要一开始就引入 embeddings 数据库、向量服务、跨应用长记忆和多 Agent 编排。无论采用哪种模型，业务代码都必须重新验证成员集合和操作范围。

### 6.4 上下文预算与版本

为单个 workspace 的证据和输出设硬上限；输入过长时保留有区分度的标题并标记 `partial`，不能把截断假装成完整分析。超预算、拒绝或语言不支持时返回“无建议”，不放宽安全边界重试。

在支持相应 API 的系统上使用 `contextSize` 和 `tokenCount(for:)` 预算完整请求，包括 instructions、schema 和预留输出。旧版本走经测试的保守长度上限及超限处理。不要把 4,096 tokens 当作所有未来 OS 的常量；也不要不加 availability 判断地把新 API 用到 macOS 26.0 路径。[A5][A6]

缓存键至少包含：规范化证据摘要、项目范围、隐私设置版本、OS/model 版本标识、prompt 版本及输出语言。若 SDK 不暴露精确 model ID，明确使用 OS build 等代理信息，不能虚构可精确识别模型权重的能力。

## 7. 异步执行：与窗口管理关键路径隔离

建议拆成 MainActor coordinator 和独立 provider actor：

```text
现有 sidebar / browser 发布链路（MainActor）
   └─ 只提交 Sendable 快照；检查语义指纹是否变化
        └─ WorkspaceTopicCoordinator
             ├─ 单飞请求 + 防抖 + 取消 + 请求代次
             └─ WorkspaceTopicProvider（独立 actor）
                  └─ 返回语义结果，不调用窗口操作
                       └─ policy / validator
                            └─ 发布完整建议（MainActor）
```

不能在 `updateWorkspaceSidebarModel()`、layout session、窗口检测回调或 SwiftUI `body` 内 `await` 模型。`Task {}` 从 MainActor 发起也不意味着内部同步预处理自动离开主线程；不要用 `Task.detached` 偷渡非 Sendable 的 AX 对象。[R4][R9][R10]

调度要求：同一时刻最多一个模型请求，其他变化合并为最新待处理快照。取消是 best-effort；即使底层请求稍后才返回，代次检查也必须丢弃结果，且不能把“UI 已取消”误当成底层空闲，立刻启动无限并发的新请求。

后台模式可从“语义稳定 2 秒后调度、每个项目自动重算间隔至少 15 秒”的**初始实验值**起步，实测后调整；这些不是现有性能数字。窗口拖动、布局切换、锁屏、功能禁用和面板不可见时暂停新后台工作，取消无效结果。隐藏面板不额外启动浏览器扫描。[R4]

缓存以有上限的 LRU 实现；每次只分析变化或缺失的项。不要逐 token 发布 UI：只发布完整且通过验证的建议，避免侧边栏持续重新布局。最后一个 provider 回调不应强制激活 App 或抢焦点。

## 8. 接受、持久化与 Undo

### 8.1 提交前再验证，而不是只在生成时验证

建议记录请求范围、语义指纹、组织修订号、隐私设置修订号及对象身份映射。用户点击“应用”后，进入现有 sidebar session 的执行点再检查一次；不能仅在按钮按下时检查，因为调度过程中状态可能继续变化。

必须满足：对象仍为同一对象、仍在同一项目、所选成员仍合格、未被手动固定或分组、相关语义输入未改变，且 store 可写。显示范围／项目切换应使旧预览失效，而不是偷偷把它应用到新范围。第一版采用**整批拒绝并要求重新生成**，而不是默默删除失效成员再应用剩余结果。

普通焦点切换不必使建议失效；窗口内容、身份、组织或隐私条件变化才使其失效。生成到提交之间不能复用已关闭／重建 workspace 的旧名字。[R1][R3]

### 8.2 一个批量编辑，不循环调用多个菜单动作

建议新增 `applySuggestedTabCollections` 组织动作（名称待实施），通过既有 `runWorkspaceSidebarSession` 路径设置一个 `undoTitle`。在批量动作内部一次构造所有目标 Collections，统一验证名字长度、控制字符和成员唯一性。

流程：验证 → 保存所需持久身份 → 一次 `workspaceSidebarOrganizationStore.update` 写入全部分组 → 更新 sidebar model → 记录一次 Undo。不要为每个组分别调用 `create`、`rename` 和另一个 session；那会产生部分成功、中间 UI 状态及多个撤销边界。[R1][R2]

组的命名不会更改 workspace 自身的名字、project 或 `workspaceOrder`。呈现继续使用 `workspaceSidebarTabSections` 的首个成员位置规则；不要求重排底层窗口或 workspace 列表。[R1]

### 8.3 不把两个文件的写入说成一个原子事务

现有 organization store 是“写入文件成功后才发布内存状态”，但身份保存还会涉及 saved-workspace store；两者并不是天然的跨文件原子事务。`saveWorkspaceSidebarIdentities` 使用延迟 `flushNow()`，实际写入失败如何暴露，需要实施阶段继续核查，不能假定 `throws` 已覆盖所有落盘错误。[R1][R11]

第一版提交协议要求：

- 先确认两个 store 的只读／版本状态；必要时为 identity flush 增加可观测的成功／失败结果。
- 身份记录确认成功后才原子写 organization 文件。组织写入失败时，不发布任何新分组，也不显示成功或登记成功 Undo。
- 对提前保存的身份记录实施条件性补偿；只撤销本操作新增且未被后续操作使用的记录。不可回滚或崩溃留下的额外身份预留必须作为已知非布局残留说明，不能声称绝对零副作用。
- 多组分配必须在 organization 层全成或全不成。若要求连两个文件的崩溃残留也完全消除，应另做 journal／统一存储事务，不以本次主题功能顺带重写持久化架构。

对该协议做写入故障注入测试，作为 P1 完成条件。

### 8.4 复用现有 Undo，但验证其实际行为

`WorkspaceSidebarTabUndo` 已包含 organization、saved records 和实时结构；后续结构编辑会使旧条目失效，标题和焦点更新不会。第一版沿用一次 Undo，不另建一套重叠的用户编辑历史。[R11]

但其恢复代码也会处理树、显示器和焦点，因此不能仅凭“这次只改 organization”就宣称它绝不触发原生窗口工作。测试必须证明接受和撤销前后布局不变，且用户之后进行的焦点／显示器导航不被恢复到旧状态。必要时增加一个限于 organization 的恢复分支，而不是绕过现有安全检查。

实时建议保存在独立的临时状态中。推理刷新不得改写 canonical organization，否则每次模型结果都可能使手动 Undo 失效。

### 8.5 第一版不升级存储格式；自动模式再处理来源

P1 接受后的组就是普通手动组，因此可保持 `sidebar-organization.json` 的 version 1，不新增必须解码的字段。建议、拒绝列表和模型缓存先只保留在会话内。

P2 的自动组放在独立内存投影中，使用独立命名空间的 ID；不能让现有菜单把临时 ID 当成 store 中的真实 Collection ID。“保留为分组”复用 P1 提交路径，然后让对应临时组退出。

若未来要持久保存 `origin`、自动管理状态或规则，则单独设计 v1 → v2 迁移，保持未知版本只读和失败不覆盖。Swift 属性有默认值不等于旧 JSON 缺失该非可选键就会自动迁移。[R1]

## 9. 具体文件计划

### 9.1 建议新增文件

以下文件**尚不存在于本次读取的目录结构中，均为建议新增**；可根据代码量合并，避免为了设计形式过度拆文件。

| 新增路径 | 职责 |
|---|---|
| `Sources/AppBundle/intelligence/WorkspaceSemanticSnapshot.swift` | 输入 DTO、隐私过滤、规范化、语义指纹 |
| `Sources/AppBundle/intelligence/WorkspaceTopicProvider.swift` | provider 合约、应用级可用性／错误、fake provider |
| `Sources/AppBundle/intelligence/AppleWorkspaceTopicProvider.swift` | availability 隔离、FoundationModels 调用、预算与版本 |
| `Sources/AppBundle/intelligence/WorkspaceTopicPolicy.swift` | 纯函数聚类、成员与命名验证、低信息量拒绝 |
| `Sources/AppBundle/intelligence/WorkspaceTopicCoordinator.swift` | 请求调度、缓存、过期检查、建议状态 |
| `Sources/AppBundle/intelligence/WorkspaceTopicProposal.swift` | 请求／建议／提交数据结构，不包含 AX 对象 |
| `Sources/AppBundle/ui/sidebar/WorkspaceSidebarTopicSuggestions.swift` | 生成状态、预览、选择、错误、接受入口 |
| `Sources/AppBundleTests/intelligence/` | policy、调度、失效、隐私与应用回归测试 |

### 9.2 修改既有文件

| 路径 | 预期修改 |
|---|---|
| `config/Config.swift` | 新增 `WorkspaceIntelligenceConfig` 和禁用默认值，保持旧配置行为 |
| `config/parseWorkspaceSidebar.swift` | 注册 `intelligence` 子表，验证模式和排除应用列表 |
| `ui/sidebar/WorkspaceSidebarModel.swift` / `WorkspaceSidebarModelStateApplier.swift` | 提交已完成的值快照；禁用时清理 coordinator；不等待模型 |
| `ui/sidebar/WorkspaceSidebarOrganizationActions.swift` | 新增一批接受操作、统一校验和 Undo 边界 |
| `tree/WorkspaceTabCollections.swift` | 必要的批量提交／身份持久化接口，保留原有同项目与 pin 语义 |
| `ui/sidebar/WorkspaceSidebarTabUndo.swift` | 增加回归覆盖；仅在测试暴露问题时加组织专用恢复分支 |
| `ui/sidebar/WorkspaceSidebarSnapshotBuilder.swift` | P1 保持 canonical collections；P2 增加 effective projection |
| `browser/BrowserTabsModel.swift` / `BrowserTabs.swift` | 浏览器阶段才加只读 freshness／privacy DTO，不重写扫描器 |
| `resources/default-config.toml` | 添加注释与关闭默认项 |
| `ui/settings/` 与 sidebar 菜单／action adapter | 接入设置和预览入口；实施前继续定位具体声明及已有控件 |
| `Sources/AppBundleTests/ui/WorkspaceSidebarNarrowWidthTest.swift` | 窄宽、长标题、交互目标边界回归 |

本表中 `resources/...` 与 `Sources/AppBundleTests/...` 为仓库根路径；其他路径相对 `Sources/AppBundle/`。现有大文件如 `WorkspaceSidebarView.swift`、`WorkspaceSidebarTabs.swift` 优先只增加小入口，视图细节放入新子视图；不借本功能做无关重构。

### 9.3 设置方案

建议沿用 parser 已有的子表模式。[R17] 第一版只实现并暴露以下键，**不是当前版本已经支持的配置**：

```toml
[workspace-sidebar.intelligence]
mode = 'off'                 # P1: off | manual
excluded-apps = []           # bundle IDs；实际规则需由配置与 UI 同步维护
```

P2 再添加 `suggest` 和 `automatic` 两种合法模式。缓存大小、防抖和阈值先用可测试的内部配置，不在初版设置里暴露十几个专业参数。浏览器本次授权是 request-scoped UI 状态，不写成永久“自动分析所有浏览器”的开关。

AI 关闭时，不初始化模型会话、不预热、不订阅额外扫描、不保留原始输入缓存。设置／菜单在旧 OS 上解释不可用原因，不影响其他窗口管理功能。`--read-only` 下禁止接受和保存；是否允许纯内存按需预览，应以统一只读策略明确实现并单测，不能绕过存储 guard。

CLI 不作为 P1 前置依赖。后续需要自动化时，再设计只读建议输出与引用 server-side proposal ID 的接受命令；不得执行客户端随意提交的窗口移动脚本。本计划不把任何尚未实现的命令当成可用命令。

## 10. 实施顺序与完成条件

### P0：小型可行性验证与测试样例

完成受 availability guard 保护的 provider、fake provider 和匿名输入集。用同一组中英混合元数据比较标签方案与简化通用模型方案；记录实际设备、OS build、冷／热启动延迟、上下文预算、错误和输出。

样例至少覆盖跨应用同一任务、同一应用不同任务、主题混合 split、重复／泛化标题，以及完全无关的窗口。优先优化误合并率，允许少分组。

**完成条件：** API 在项目工具链下可编译；可用与不可用路径可控；所有后续 UI 测试可用 fake provider 运行；模型效果不理想的样例有明确 abstain 策略。未通过前不做常驻自动模式。

### P1：按需建议 → 预览 → 批量接受 → Undo

从实际完成构建的 sidebar 快照提取候选，在 `.tabs` 模式加入菜单入口，完成 policy、预览和存储协议，保证一个接受操作一个撤销边界。

**完成条件：** 不触发额外 AX 扫描；取消零写入；接受只改变分组组织；没有窗口移动、关闭、split 变化或抢焦点；只读／写入失败不显示部分成功；macOS 13+ 的非 AI 路径不退化。

### P2：后台建议与自动投影

加入语义事件调度、缓存和稳定组身份。默认仍不开启自动组织；开启后只组织未被手动管理的项。自动投影的菜单、拖拽和“保留为分组”必须与持久分组明确区分。

**完成条件：** 固定输入不会反复调用模型；用户交互期间不跳行；自动结果不使手动 Undo 失效；关闭后准确回到手动视图；模型失败保留稳定旧视图或退回未分组，不抖动重试。

### P3：可选浏览器上下文增强

复用现有 Safari 桥接和浏览器缓存，先补齐可靠的 privacy、provenance、freshness 传递，再逐应用启用自动语义证据。保留无扩展、权限撤销、读取失败和 unknown 的降级。

**完成条件：** 已知私密与无法确认的数据默认不进入自动输入；陈旧缓存不会作为新证据；browser tab 的会话引用不会泄漏成 workspace 身份；不增加为了 AI 而遍历隐藏窗口的行为。

## 11. 验证矩阵

以下均为待运行的验收要求，**不是已通过的测试结果**。

### 11.1 纯逻辑与模拟 provider

| 场景 | 必须满足 |
|---|---|
| 同项目的不同 App，具有明确共同主题 | 可以建议同组，成员仍是 workspace |
| 同一个 App 的不相关任务 | 不仅凭应用名合并 |
| split 含多个任务 | 不拆分；证据不足时保持未分组 |
| 固定／手动分组／排除项 | 模型之前过滤，提交之前再验证 |
| 生成期间关闭、重建或重命名 workspace | 旧 proposal 拒绝；不能按重用名字误应用 |
| 生成期间移动项目或改分组 | 旧 proposal 拒绝；不覆盖手动动作 |
| 仅焦点、图标、音频、hover 变化 | 不重复推理；不无故失效 |
| provider 超时／拒绝／输出无意义标签 | 显示无建议或适当状态，没有副作用 |
| 取消后旧回调晚到 | 不发布，不提交，不引发并发风暴 |
| 无痕状态 unknown、缓存过旧 | 自动输入中不存在该证据 |
| 相同输入重复请求 | 命中有版本边界的缓存；输出顺序稳定 |
| 命名包含控制字符／过长／空白 | 应用级验证拒绝或安全规范化 |

调度测试使用 fake clock；provider 测试使用可控的延迟、失败和取消，不把真实 Apple 模型输出作为普通 XCTest 的必需依赖。

### 11.2 组织、持久化和原生 UI

必须覆盖一次接受多个组、一次撤销恢复；接受不取消 pins；项目与显示器不变；搜索中的组保持展开；组内活动 workspace 不被折叠隐藏。上述披露／展开规则已经存在，应继续沿用。[R1]

注入 organization 文件写入失败、saved identity flush 失败、只读、损坏 JSON、未知文件版本及组织写入之前的中断，检查是否出现部分成功、身份误绑定或错误覆盖。测试跨重启后成员不会绑定到另一个同名临时 workspace。[R1][R11]

原生 UI 参考已有 `NSHostingView` 测试，在 160、180、200、240、320 宽度覆盖长中文／英文标题、生成中状态、错误提示、预览 checkbox、group 菜单、拖拽目标和 Reduce Motion。新增控件不应越界，图标不能是唯一可访问标签。[R14]

多显示器测试包括 This Display / All Displays、Other Projects、共享 pins、显示器断开，以及接受后用户再切焦点再 Undo；不得触发物理移动所用的 Override 流程。

### 11.3 性能目标与实际测量

建议使用 10、30、100 个窗口的代表性场景。以下是目标，不是测得的数据：

| 指标 | 初始验收目标 |
|---|---|
| AI 关闭 | AI 推理次数为 0，额外浏览器扫描为 0 |
| 手动预览取消 | 持久化写入为 0，窗口布局动作增量为 0 |
| steady-state 不变输入 | 新推理次数为 0 |
| 并发 | 最多一个有效 provider 请求；取消中的旧请求可控 |
| 主线程新增快照工作 | 代表性数据上 P95 目标低于 5 ms；达不到就缩减／增量化 |
| 输入隐私 | 默认诊断中没有标题、域名或完整 prompt |
| 窗口管理体验 | 对比关闭功能的基线，切换、拖动与 Dock 动画无明显新增卡顿 |

用现有 Dock 性能工具和 Instruments 测量；模型延迟另列，不把它混成 UI 阻塞时间。Apple 的 Foundation Models Instruments 支持分析生成和 token 使用，但采集真实内容前需要明确授权并清理敏感诊断。[A6]

### 11.4 构建和运行

按仓库贡献指南在 macOS / arm64 工具链运行：[R16]

```sh
swift --version
swift build --arch arm64
swift test --arch arm64 --filter WorkspaceSidebar
swift test --arch arm64 --filter WorkspaceTopic
swift test --arch arm64
```

`WorkspaceTopic` 是本计划建议采用的新测试类前缀，目前不应宣称仓库已有该测试集。先以 fake provider 跑自动测试，再在 Apple Intelligence 可用／关闭／未就绪的真实 Mac 上跑 provider 验证。至少覆盖旧系统启动以及使用新模型的目标系统；未经测试的 OS／多显示器场景在交付说明中列明。

本计划不要求启动 GitHub Actions、发布版本或使用签名凭据。将来实施源码变更时，依仓库届时的 `AGENTS.md` 执行本地测试与独立审阅，不能把本文当成已经获得代码审阅或发布授权。

## 12. 给实施 Agent 的交接摘要

目标是让 WinMux 的现有 workspace tabs 像浏览器标签一样按内容主题组织，但 AI 不掌握窗口布局控制权。

先实现 P0 与 P1。保留 macOS 13 部署目标，将 FoundationModels 隔离为可选 provider。以 `WorkspaceTabCollection` 为持久落点，以 `BrowserTabsModel` 为可选证据来源，以既有组织 action / Undo 为提交边界。不要另建浏览器扩展，不要直接编辑 Safari 数据库，不要新建一套窗口层级。

最需要验证的不是“模型能否生成一个组名”，而是：**稀疏标题能否形成有用主题、旧结果能否被可靠拒绝、批量落盘是否有可解释的失败状态，以及所有过程是否不干扰窗口切换。**

实施前仍需继续阅读、本文未完整验证的部分：saved-workspace store 的落盘错误与补偿行为；sidebar action 枚举／adapter 的完整路由；settings 实际编辑入口；Safari 扩展协议是否已有未透传到 `BrowserTab` 的隐私字段。这些是具体的后续代码核查点，不应被当成现有能力。

---

## 来源与代码定位

仓库来源全部固定在同一提交；链接可以直接交给实施 Agent。Apple 文档为调研时可访问的官方页面，SDK 符号的最终 availability 和错误类型仍以实施使用的 SDK 编译结果为准。

[R1]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/tree/WorkspaceTabCollections.swift "Collection、持久身份、原子写入与呈现规则"
[R2]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/ui/sidebar/WorkspaceSidebarOrganizationActions.swift "既有组织操作与 Undo 边界"
[R3]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/tree/WorkspaceType.swift "实时身份、existing 与 get 的区别"
[R4]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/browser/BrowserTabsModel.swift "浏览器读取调度与缓存发布"
[R5]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/browser/BrowserTabs.swift "浏览器 DTO、会话身份与缓存过期规则"
[R6]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/config/Config.swift "Tabs 模式、usesBrowserTabs 与配置类型"
[R7]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/ui/sidebar/WorkspaceSidebarWorkspaceSnapshotBuilder.swift "工作区快照、范围与 pins"
[R8]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/ui/sidebar/WorkspaceSidebarWindowItemBuilder.swift "已有窗口标题读取与元数据"
[R9]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/ui/sidebar/WorkspaceSidebarModel.swift "侧边栏更新生命周期"
[R10]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/ui/sidebar/WorkspaceSidebarModelStateApplier.swift "快照发布与条件刷新"
[R11]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/ui/sidebar/WorkspaceSidebarTabUndo.swift "一次可逆编辑与状态安全检查"
[R12]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/ui/sidebar/WorkspaceSidebarSnapshotBuilder.swift "Collection 进入 UI 配置的入口"
[R13]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/tree/WorkspaceIdentity.swift "身份与 lifecycle 值类型"
[R14]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundleTests/ui/WorkspaceSidebarNarrowWidthTest.swift "原生窄侧边栏布局回归模式"
[R15]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Package.swift "部署目标、Swift tools 与目标组织"
[R16]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/AGENTS.md "工具链、测试、审阅与发布约束"
[R17]: https://github.com/alanzchen/winmux/blob/ee150c27b209460c3da165db4ad91da0a693cae6/Sources/AppBundle/config/parseWorkspaceSidebar.swift "既有 TOML 子表解析模式"
[A1]: https://developer.apple.com/documentation/FoundationModels "Foundation Models 框架与结构化生成"
[A2]: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/usecase/contenttagging "contentTagging 只返回分类标签"
[A3]: https://developer.apple.com/videos/play/wwdc2025/286/ "Meet the Foundation Models framework；18:39–19:56 的标签与可用性示例"
[A4]: https://developer.apple.com/documentation/foundationmodels/languagemodelsession "有状态会话"
[A5]: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel "设备端模型、availability、模型版本与上下文能力"
[A6]: https://developer.apple.com/documentation/updates/foundationmodels "26.4／27 的模型、预算、错误与 Instruments 更新"
[A7]: https://developer.apple.com/documentation/FoundationModels/improving-the-safety-of-generative-model-output "不可信内容与 instructions 的边界"
