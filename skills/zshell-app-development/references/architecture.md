# Zshell 架构参考

模块索引按职责分组，用于快速定位；具体行为以源码为准。路径都相对 `mac/zshell/`。

## 模块索引

| 关注点 | 文件 |
| --- | --- |
| 进程入口与 app 生命周期 | `main.swift`、`zshellApp.swift`、`ContentView.swift`、`WindowChrome.swift` |
| 项目与会话 | `Project.swift`、`SessionStore.swift`、`SessionInfoModel.swift` |
| 面板与布局 | `Panes.swift`、`PaneLayoutView.swift`、`TerminalHostView.swift`、`TabSwitcherView.swift` |
| 终端后端抽象 | `TerminalBackend.swift` |
| Ghostty 后端 | `ZshellTerminalView.swift`、`ZshellTerminalView+Ghostty.swift` |
| Alacritty 后端 | `Alacritty/`、`../Vendor/alacritty-bridge` |
| 终端周边 | `TerminalManager.swift`、`TerminalSession.swift`、`TerminalHistory.swift`、`TerminalFind*.swift`、`TerminalFont.swift`、`TerminalCursorSettings*.swift`、`GlobalTerminalOverlay.swift`、`TerminalNotificationService.swift` |
| 侧栏与 Git | `SidebarView.swift`、`RightSidebarView.swift`、`GitStatusModel.swift`、`RecentCommitsView.swift`、`SidebarResizeHandle.swift`、`SidebarTypography.swift` |
| 文件树与查看 | `FileTreeModel.swift`、`FileViewerView.swift`、`MaterialFileIcon.swift`、`FinderService.swift`、`ProcessWorkingDirectory.swift` |
| 编辑器与 Diff | `SourceTextEditor.swift`、`EditorFind.swift`、`DiffViewerView.swift`、`SyntaxHighlighting.swift`、`SyntaxHighlightPlugin.swift` |
| 命令面板与浏览器 | `CommandPaletteView.swift`、`BrowserView.swift` |
| 设置与主题 | `AppSettings.swift`、`SettingsView.swift`、`Theme.swift`、`AgentCLISupportSettingsView.swift` |
| 自动化与 in-app CLI | `ZshellCommandLine.swift`、`ZshellCLIService.swift`、`ZshellAutomation*.swift`、`AgentAutomation.swift`、`ZshellAgentIntegrations.swift`、`AgentIntegrations/`、`AgentStatusBadge.swift` |
| 更新 | `Updater.swift` |
| 通用 UI 与性能 | `OverlayScrollbarView.swift`、`VisualEffectView.swift`、`Tooltip.swift`、`FPSCounter.swift`、`MainActorIsolation.swift` |

## 双后端对齐清单

`TerminalBackend` 只有两个 case，`isAvailable` 对两者都为 `true`，所以 Settings 会显示
Backend 选择行，两条路径都可能是用户的日常路径。改 surface 能力时逐项过一遍：

`TerminalBackendSurface` 需要后端提供：`events`、`onBecomeFirstResponder`、`splitTarget`、
`hasEffectiveTerminalFocus`、`foregroundPid`、`hasSelection`、`setSurfaceVisible(_:)`、
`applyAppearance()`、`setBackgroundOpacity(_:)`、`detach()`、`sendText(_:)`、
`sendApplicationScroll(lines:)`、`readVisibleText(maxLines:maxColumns:)`、`clearScreen()`、
`scroll(toFraction:)`、`beginFind(_:)`、`endFind()`、`stepFind(forward:)`、`findSelection()`、
`exportScreenFile()`、`exportScrollbackFile()`。

`TerminalBackendEvents` 是回报方向：标题、工作目录、单元格尺寸、bell、shell 集成事件、
关闭（带 `processAlive`）、桌面通知、打开 URL、链接目标解析、滚动位置、剪贴板确认、
以及查找的开始/结束/总数/当前项。

必须保持的契约：

- surface 是 `NSView`，分屏和切 tab 时同一实例被 reparent，PTY 状态、选中和 scrollback
  靠这个存活，不要用重建视图的方式实现布局变化。
- `detach()` 只释放模拟器与子进程记账，视图本体要活过这次调用，避免拆面板时把视图从布局里抽走。
- `setSurfaceVisible(false)` 的 parked 面板仍要继续排空 PTY 事件，但应释放渲染器内存。
- `readVisibleText` 必须有界，不要走完整 scrollback；有内存快照就用快照，否则用有界的屏幕导出。
- `exportScreenFile()` / `exportScrollbackFile()` 必须把文件写成进程临时目录下一个**新建子目录里的唯一条目**；
  Zshell 会先校验这一点，读完连文件带目录一起删。`exportScrollbackFile()` 返回 nil 同时也是
  "这是全屏 TUI 而不是滚动过的 shell" 的判据。
- `sendApplicationScroll(lines:)` 的模式判断存在后端差异：Alacritty 在普通 scrollback 模式
  返回 `false`，Ghostty 对非零滚动合成事件后返回 `true`。涉及它时读两侧实现并验证实际滚动，
  不把返回值当成两个后端一致的模式检测接口。
- 剪贴板 `Kind.programRead`（OSC 52）绝不能不问就放行：任何输出能到达终端的程序，包括远端
  SSH 主机，都能借此把 macOS 剪贴板读走。
- 提示行局部选中编辑（`PromptInputSelection`）只对 zsh 开启，按 Unicode scalar 计数而不是
  Swift `Character`，因为 ZLE 按 scalar 移动。
- shell 集成存在既有差距：Alacritty 在 PTY 边界提取全部四个 OSC 133 标记，libghostty 目前只
  暴露完成的命令与耗时。新功能要在这个差距下仍然可用，不要假设两侧语义一致。
- `TERM_PROGRAM` 两个后端都报 `ghostty`，那是协议能力标识；Zshell 自己的 surface 身份用
  `environmentName`（`ghostty` / `alacritty`）。不要用 `TERM_PROGRAM` 判断后端。

## Vendor 的三条硬约束

### STTextView fork 必须是 root package

`mac/Vendor/STTextView` 是 STTextView 的 fork，含 3 个文件里 5 处 `// zshell patch`，
`mac/zshell.xcodeproj` 以 **root package**（工程顶层组里的文件夹）方式引用它，
不是通过 **Add Package Dependency… > Add Local…**。原因：`STTextView-Plugin-Neon` 依赖
`krzyzanowskim/STTextView`，SwiftPM 用路径最后一段推导 package identity，fork 和远端都叫
`sttextview`，只有 root package 才能覆盖同名依赖。登记成 local package 会得到
`Conflicting identity for sttextview` 警告，Apple 已说明它将来会变成错误。
需要重新添加时把文件夹拖进工程，永远不要走 **Add Local…**。

### libghostty-spm 的源码与二进制

`mac/Vendor/libghostty-spm` 当前是直接版本化的源码目录，保留其中的本地补丁。
读取其 `Package.swift` 的 `binaryTarget` 来判断使用本地 XCFramework 还是远端下载；
本地 `path` 要检查文件完整性，远端 `url` 要保留 checksum，不能只根据历史文档判断。
先区分源码缺失、二进制下载失败与构建缓存路径失效，不把它们都归因于 submodule。

### Alacritty 桥的构建阶段受脚本沙箱限制

`mac/scripts/build-alacritty-bridge.sh` 由 Xcode 在 Compile Sources 之前作为构建阶段运行，
产出 `${BUILT_PRODUCTS_DIR}/alacritty-bridge/libzshell_alacritty.a`。工程开启了
`ENABLE_USER_SCRIPT_SANDBOXING`，脚本只能写自己声明的输出和 `TARGET_TEMP_DIR`，
不能写 `SRCROOT`，也不能写 `DERIVED_FILE_DIR`。由此产生的几个既定做法不要"顺手优化"掉：

- crate 被复制（不是 symlink）到 `TARGET_TEMP_DIR` 再构建：cargo 即使带 `--locked` 也会以写方式
  打开 `Cargo.lock`，而 symlink 的 manifest 会让 cargo 解析回只读的源码树。
- `CARGO_TARGET_DIR` 故意放在声明输出目录之外，清理产物树不会丢掉增量缓存。
- 一律 `cargo build --release --locked`：这是终端渲染热路径，debug 版 VT parser 打字时能感觉到卡。
  `panic = "abort"` 也只作用于 release profile。
- 按 `$ARCHS` 每个架构编一份再 `lipo`，universal release 才能拿到 universal 归档。
- Xcode 的 PATH 被裁剪过，脚本会回退到 `~/.cargo/bin`、`/opt/homebrew/bin`、`/usr/local/bin`
  找 cargo/rustc。缺目标架构时脚本直接报错并给出 `rustup target add …` 提示，因为安装要写
  `~/.rustup`，沙箱不允许，报在这里比后面出现莫名的链接错误好。
