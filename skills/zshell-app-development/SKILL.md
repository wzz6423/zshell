---
name: zshell-app-development
description: Zshell（原生 macOS 终端工作区）仓库的 app 开发工作流。在改动 mac/ 下的 Swift/AppKit 界面、两种终端后端（Ghostty / Alacritty）、Alacritty Rust 桥、mac/scripts 发布脚本或 web/ 站点时使用。覆盖环境准备、AppKit 与双后端约束、Debug/Release 身份隔离、构建与验证矩阵、产物清理和 PR 要求。
---

# Zshell App 开发

Zshell 是原生 macOS 终端工作区：项目、面板、文件树、Git 面板、编辑器、Diff 视图。
仓库是多包结构。应用的 Makefile 命令在仓库根执行，Bun 命令在各自包目录执行。

## 先读，再改

1. 先记录 `git status --short`，保留用户已有和并行任务的修改；读 `AGENTS.md`（架构底线；仓库里唯一的 agent 指令文件，`CLAUDE.md` 一类的工具专属副本已被 git 忽略，需要就在本地做软链）、`PRODUCT.md`（产品取舍）、`CONTRIBUTING.md`（构建、验证、PR 规则）。
2. 读要改的文件和它的同目录邻居，沿用该文件的命名、注释密度与写法；注释解释"为什么"。
3. 复用已有类型和工具，不新造并行实现。
4. 行为不确定时读源码确认，不要从文档或命名推断。

## 仓库布局

| 路径 | 内容 |
| --- | --- |
| `mac/zshell/` | app 源码（AppKit + 少量遗留 SwiftUI）、`Info.plist`、字符串目录、资源 |
| `mac/zshell.xcodeproj` | 唯一 Xcode 工程，scheme `zshell` |
| `mac/Vendor/` | `libghostty-spm`、`alacritty-bridge`（Rust）、`STTextView` fork、`TreeSitterTSX` |
| `mac/Config/` | `Debug.xcconfig` 与被忽略的 `Local.xcconfig` |
| `mac/scripts/` | Bun + TypeScript 发布脚本、Alacritty 桥构建脚本 |
| `web/` | 站点与用户文档，独立包和锁文件 |
| `skills/` | 本仓库给 coding agent 的开发与发布 skill |
| `mac/zshell/Skills/zshell-automation` | **app 内置**运行时 skill，随 app 分发，不是仓库开发 skill |

只有在改 app 内置自动化能力时才动 `mac/zshell/Skills/`，它与本 skill 无关。

## 环境准备

- 完整 Xcode（不是仅 Command Line Tools）。只有 Xcode beta 时在命令前加
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。
- Bun：`mac/` 与 `web/` 各自 `bun install --frozen-lockfile`，两个包锁文件独立。
- Rust 工具链（rustup）：Alacritty 后端的静态库由 Xcode 构建阶段调 cargo 编译。
  要构建第二个架构另需 `rustup target add x86_64-apple-darwin`。
- `mac/Vendor/libghostty-spm` 当前直接随仓库版本化，必须保留其中的本地补丁。
  构建前检查 `Package.swift` 的 `binaryTarget`：本地 `path` 必须有对应 XCFramework；
  远端 `url` 则按声明的 checksum 获取。沿用当前依赖方式，不为构建擅自切换。
- 本地签名：`cp mac/Config/Local.example.xcconfig mac/Config/Local.xcconfig`，
  只替换 `DEVELOPMENT_TEAM`，保留 `CODE_SIGN_IDENTITY = Apple Development`。
  该文件被 git 忽略，永不提交。Developer ID 证书、公证凭据、Sparkle 私钥属于发布材料，
  只按 `mac/RELEASING.md` 配置，不放进 `Local.xcconfig` 或仓库。

## 架构约束

- **AppKit 优先。** SwiftUI 是遗留实现，不得新增或扩展；实质改动某个 SwiftUI 视图时，
  把受影响的 UI 迁到 AppKit。UI 架构以运行时性能优先于实现便利。
- **两种终端后端必须同时成立。** `TerminalBackend` 有 `libghostty`（`ZshellTerminalView`，
  Metal）和 `alacritty`（`AlacrittyTerminalView`，Rust 桥 + Metal/CoreText），fallback 是
  `libghostty`。面板级能力一律经 `TerminalBackendSurface` / `TerminalBackendEvents`，
  会话、面板、历史、查找层不出现任何模拟器专有类型。给 surface 加能力时两个后端都要实现，
  能力差异必须明确说明，不要把某个后端的行为当成另一后端已经具备的能力。
- 模块地图、双后端对齐清单、Vendor 的三条硬约束见
  [references/architecture.md](references/architecture.md)。

## Debug / Release 身份隔离

Debug 构建是独立身份，可与已安装的正式版并存：

- bundle id `sh.zshell.dev`；Release 是 `sh.zshell`，它是 Sparkle 与代码签名的身份，不得改动
- bundle 名 `zshell Debug.app`（`WRAPPER_NAME` 取自 `ZSHELL_DISPLAY_NAME`），图标 `AppIconDebug`
- 配置写 `~/.config/zshell-dev/config.toml`，正式版是 `~/.config/zshell/config.toml`
- 会话快照、侧栏宽度、Sparkle 偏好都按各自 bundle id 分开存
- `Updater` 在 `DEBUG` 下不启动 Sparkle，更新流程无法在 Debug 里验证；要验更新走 `skills/zshell-release`

## 构建与运行

在仓库根执行，根 `Makefile` 委派到 `mac/`：

```sh
make run      # 构建 Debug 并启动
make update   # 先 stop 再 run
make stop     # 结束 sh.zshell.dev
make clean    # 停 app，删 mac/build、Rust target、web 产物
```

`make run` 用固定 DerivedData（`mac/build/debug`），并在 `open` 时清掉
`ZSHELL_CLI_STATE` / `ZSHELL_CLI_TOKEN`——Zshell 托管的 shell 会导出这两个变量，
继承后新进程会把自己当成 in-app CLI 而不是启动 UI。在 Zshell 面板里起 Debug 版必须走
`make run`，不要手动 `open` 那个 bundle。

只需要一次纯构建时：

```sh
xcodebuild -project mac/zshell.xcodeproj -scheme zshell -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
```

## 本地化

新增用户可见文本后先构建一次（构建开启了字符串提取），再到
`mac/zshell/Localizable.xcstrings` 补 `zh-Hans` 与 `ja`。运行时需要 `String` 的地方用
`String(localized:comment:)`；用户内容、文件名、终端输出不作为本地化查找键；AppKit 控件直接显示原值。
细节见 `mac/LOCALIZATION.md`。

## 验证

app 没有单元测试目标：**构建、运行、实际操作改动路径**就是验证，UI 改动附截图或录屏。
最小组合：

```sh
make run
codesign --verify --deep --strict --verbose=2 \
  'mac/build/debug/Build/Products/Debug/zshell Debug.app'
(cd mac/Vendor/alacritty-bridge && cargo test --locked)   # 改桥时
(cd mac && bunx tsc --noEmit)                             # 改 mac/scripts 时
(cd web && bun run typecheck && bun run build)            # 改站点时
```

风险相关改动追加验证：

- 签名、entitlements、bundle id、Sparkle 键值：跑 `codesign --verify`，并确认 Debug 与正式版仍能并存。
- 自动化 CLI（`Zshell*Automation*`、`ZshellCLIService`）：在 Zshell 面板内实测
  `zshell +pane` / `zshell +agent`，确认跨项目目标仍被拒绝。
- 破坏性动作（删文件、Git 写操作、清 scrollback）：先在一次性临时仓库里跑，确认可撤销。
- 终端 surface 改动：两个后端各测一遍，在 Settings 切换 Backend 后新开终端（既有终端不切换后端）。

完整检查矩阵、依赖安装、CI 路径作用域与常见构建失败见
[references/verify.md](references/verify.md)。

## 清理

优先把一次性构建放进 `mktemp -d` 创建的目录；完成后停止本次测试实例，删除本次生成的
binary、构建目录、日志和临时文件。保留用户已有产物、依赖和其他任务的进程。
`make clean` 会停止所有 `sh.zshell.dev` 实例并删除共享构建目录，只有这些资源均属于
本次任务或用户要求整体清理时才执行。检查 `git status --short`，不把产物或签名材料纳入 Git。

## 提交与 PR

- 分支前缀、Conventional Commits 标题、PR 正文七个小节、Validation 三态、AI Attribution
  的具体规则以 `CONTRIBUTING.md` 为准。
- 绝不在 PR 里改 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，版本只由发布流程推进。
- `CHANGELOG.md` 只写将要发布的用户可见结果，不记录过程中的修复、重构和已自愈的回归。
- 改到用户可见行为、构建方式或发布流程时，同步更新对应文档。
