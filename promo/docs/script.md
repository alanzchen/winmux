# Narration script

The narration is AI-generated with Google Gemini TTS (voice Kore).
- **Voice direction:** warm, confident and unhurried, in neutral American English, at about 150 words per minute.
- **Pronunciation:** "WinMux" is **WIN-mux**.
- **Timing:** each line starts on the 120 BPM grid (`cues/beats.json`) and must end before its window closes. `cues/narration.json` is the machine-readable copy.

| Line | Starts | Window ends | Text | 中文 |
|---|---|---|---|---|
| L01 | 0:01.50 | 0:05.00 | Every project brings its own windows. | 每个项目，都带着自己的一堆窗口。 |
| L02 | 0:05.50 | 0:10.00 | Soon, you're searching more than working. | 很快，你找窗口的时间比干活还多。 |
| L03 | 0:14.00 | 0:18.25 | Meet WinMux, a tiling window manager for your Mac. | 认识一下 WinMux：为你的 Mac 打造的平铺式窗口管理器。 |
| L04 | 0:18.50 | 0:22.00 | Every window, in its place. | 每个窗口，各就各位。 |
| L05 | 0:24.25 | 0:29.75 | In the sidebar, every workspace is a tab, one click away. | 在侧边栏里，每个工作区都是一个标签页，一键即达。 |
| L06 | 0:29.75 | 0:35.75 | Projects keep each context apart. Switch, and the sidebar follows. | 项目让不同的工作情境互不干扰。一切换，侧边栏随之切换。 |
| L07 | 0:36.00 | 0:40.00 | Group related tabs, and fold away the rest. | 把相关的标签页分组，其余的收起来。 |
| L08 | 0:40.25 | 0:43.75 | Pin the ones you always come back to. | 常用的那些，就固定在顶部。 |
| L09 | 0:48.50 | 0:51.50 | And it works across displays. | 而且，它能跨显示器工作。 |
| L10 | 0:52.00 | 0:56.50 | Drag a tab, and your other displays appear as rails. | 拖动一个标签页，其他显示器会以竖条的形式出现在侧边栏旁。 |
| L11 | 0:56.50 | 1:01.00 | Pause to open its list. Drop, and it's there. | 停一下，就能打开它的列表。松手，标签页就过去了。 |
| L12 | 1:02.00 | 1:04.50 | Share your pins across displays. | 置顶标签可以在所有显示器间共享。 |
| L13 | 1:04.75 | 1:08.50 | Click one, and it comes to your screen. | 点一下，它就来到你当前的屏幕。 |
| L14 | 1:08.50 | 1:12.00 | A subtle badge marks the ones on other displays. | 一个低调的小标记，标出位于其他显示器上的置顶标签。 |
| L15 | 1:12.00 | 1:16.00 | Reorder them anywhere. No window changes screens. | 在任何屏幕上调整顺序，都不会让窗口换屏。 |
| L16 | 1:18.25 | 1:22.00 | WinMux. Your windows, in flow. | WinMux。让你的窗口，行云流水。 |

## What the lines claim, and where it's documented

| Lines | Claim | Source |
|---|---|---|
| L03 | Automatic tiling on the Mac | The root [README](../../README.md) |
| L05–L08 | Tabs, projects, groups that collapse, and pins | [docs/configuration.md](../../docs/configuration.md), Tabs |
| L10–L11 | A rail for each other display beside the sidebar during a drag; pausing on one opens that display's list; a drop moves the tab there | `Sources/AppBundle/ui/sidebar/WorkspaceSidebarDropDestination*.swift` |
| L12–L15 | `share-pinned-tabs`; clicking a pin brings its tab to that display; the faint display outline on pins kept on another display; rearranging shared pins never moves a tab to another display | [docs/configuration.md](../../docs/configuration.md), Tabs |

The narration makes no performance metrics, testimonials or hardware-validation claims.
