# 为 Zshell 贡献

**简体中文** | [English](CONTRIBUTING.md)

除了小修小补之外的改动，请先开一个 Issue —— Zshell 会拒绝那些更适合别的工具去做的
功能，早点弄清楚这一点比做完再说更省事。

## Issue

感谢你开 Issue。请先搜索已有的 Issue 和 Discussion，避免重复报告。

- Bug 报告用 `[Bug] 简短的问题描述`，例如 `[Bug] Closing the git panel loses focus in the active pane`。请写明 zshell 版本、macOS 版本和机型、安装方式、复现步骤、预期行为和实际行为。
- 功能请求用 `[Feature] 简短的需求描述`，例如 `[Feature] Remember the file tree scroll position per project`。请描述问题、你希望的方案，以及你考虑过的替代做法。
- 在表单里选择一个 **Area**。这是必填项，决定 `area:*` 标签：`Feature Development`、`Bug Fix`、`CI & Build`、`Documentation` 或 `Community & Discussion`。简体中文表单提供相同的选项，映射到相同的标签。
- 如果问题涉及终端本身，请说明它需要哪个终端后端：Ghostty 还是 Alacritty。两者是独立实现，一个 Bug 很少同时出现在两边。
- 请从日志、截图和录屏中移除 token、账号信息、本地路径和其他敏感内容。
- 安全漏洞请通过[安全公告](https://github.com/wzz6423/zshell/security/advisories/new)私下报告，不要开公开 Issue。
- 自动化会同时打上 `bug` 或 `enhancement` 以及对应的 `area:*` 标签，其他标签一概不动。如果标题前缀或某个必填项不符合表单要求，它还会加上 `needs-more-info`，并保留一条评论列出缺失的内容；编辑 Issue 后那条评论会自动更新。

## 开发环境

```bash
git clone https://github.com/wzz6423/zshell.git
```

构建应用需要完整安装 Xcode。`web/` 和 `mac/scripts/` 还需要 Bun。

需要 Rust 工具链（[rustup](https://rustup.rs)）：Alacritty 后端的桥接层位于
`mac/Vendor/alacritty-bridge`，是一个由 Xcode 构建阶段编译的 Rust 静态库。为第二种
架构构建时也要安装对应 target —— `rustup target add x86_64-apple-darwin`。

`mac/Vendor/STTextView` 是 STTextView 的一个 fork，在三个文件中共有五处
`// zshell patch` 标记，并且 `mac/zshell.xcodeproj` 是把它作为 *root package*
引用的 —— 即工程顶层分组里的一个文件夹 —— 而不是通过 Xcode 的
**Add Package Dependency… > Add Local…**。这个区别很关键：
`STTextView-Plugin-Neon` 依赖 `krzyzanowskim/STTextView`，而 SwiftPM 用路径最后一段
推导包标识，于是 fork 和远程仓库都声称自己是 `sttextview`。只有 root package 才能
覆盖同标识的依赖。如果把 fork 注册成 local package reference，它在解析时会带出
`Conflicting identity for sttextview` 警告，Apple 已表示该警告将来会变成错误。
重新添加这个 fork 时请把文件夹拖进工程，绝不要走 **Add Local…**。

### 本地开发签名

Debug 构建使用你自己登录钥匙串里的 Apple Development 证书。先从被跟踪的模板创建那个
被忽略的本地配置文件，然后只替换其中占位的 Team ID：

```bash
cp mac/Config/Local.example.xcconfig mac/Config/Local.xcconfig
```

`mac/Config/Local.xcconfig` 已被忽略，绝不可提交。保持
`CODE_SIGN_IDENTITY = Apple Development` 不变。确认本机有可用的 Apple Development
身份，然后把 `DEVELOPMENT_TEAM` 设为该证书主题中的 `OU` 值：

```bash
security find-identity -v -p codesigning
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

Developer ID 证书、公证凭据和 Sparkle 私钥都属于仅用于发布的材料。只能按
[RELEASING.md](mac/RELEASING.md) 的说明配置，不要放进 `Local.xcconfig` 或仓库里。

### 构建与验证

打开 `mac/zshell.xcodeproj` 运行 `zshell` scheme，或者：

```bash
xcodebuild -project mac/zshell.xcodeproj -scheme zshell -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

如果你只装了 Xcode beta，请加上
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。

`make run` 一步完成构建和启动 Debug 应用，`make update` 会重启已在运行的实例。
用下面的命令验证产出的 bundle：

```bash
make run
codesign --verify --deep --strict --verbose=2 'mac/build/debug/Build/Products/Debug/zshell Debug.app'
```

`make build-package` 在本地产出固定证书签名的 arm64、x86_64、Universal DMG/ZIP 和签名更新源，不发布。
发布身份和 Sparkle 密钥按 [RELEASING.md](mac/RELEASING.md) 配置。`make clean` 会停止 Debug 应用并清除构建产物和网站产物。这些命令都写入
`mac/build/` 或其他被忽略的输出目录；提交前请清理掉。

Debug 构建的 bundle id 是 `sh.zshell.dev`，状态独立保存，因此可以和已安装的 Zshell
并存而不互相覆盖：设置写入 `~/.config/zshell-dev/config.toml`，会话快照、侧栏宽度和
Sparkle 偏好都存在这个独立 bundle id 下。

仓库级 skill 位于 [`skills/`](skills/)。实现和验证用
[应用开发](skills/zshell-app-development/SKILL.md)，发布准备或发布用
[release](skills/zshell-release/SKILL.md)。随应用打包的 `zshell-automation` skill 仍在
`mac/zshell/Skills/`。

## 官网与文档

站点在 [`web/`](web/README.md)，用户文档是 `web/content/docs` 下的 MDX。它是写给使用
应用的人看的 —— 只有在开发应用时才用得上的内容应该写进本文件。本地命令、预渲染、
部署和文档 URL 见[官网指南](web/README.md)。

## 本地化

Zshell 的开发语言是英文，简体中文和日文翻译维护在 Xcode String Catalog 中。翻译现有
文案、新增语言、测试本地化以及编写可本地化的 Swift 代码，见
[LOCALIZATION.md](mac/LOCALIZATION.md)。

欢迎只做翻译的 Pull Request。Xcode 的 catalog 编辑器和 XLIFF 导入导出流程都可以用，
贡献者不需要改 Swift 代码。

## 分支与提交

- 从最新的 `main` 创建分支，并以 Pull Request 将要声明的类型作为前缀 —— `feat/`（或 `feature/`）、`fix/`、`docs/`、`style/`、`refactor/`、`perf/`、`test/`、`chore/`、`build/`、`ci/` 或 `revert/` —— 例如 `fix/pane-focus-loss` 或 `ci/skip-directive-timing`。
- 使用英文的 [Conventional Commits](https://www.conventionalcommits.org/) 格式，例如 `type(scope): description` 或 `fix(terminal): restore focus after closing the git panel`。
- 一个分支、一个 Pull Request 只围绕一个明确目标；不要夹带纯格式改动和无关重构。
- `publish-v*` 分支保留给发布维护使用。其他贡献一律提交到 `main`。

## Pull Request

感谢你提交 Pull Request。等待评审期间，请对照下面这些要求自查。

- **PR 标题**必须使用英文的 Conventional Commit 主题，例如：
  - `feat(terminal): add per-pane scrollback search`
  - `fix(git): resolve stale diff after a branch switch`
  - `docs: update contributing guidelines`
  允许的类型是 `feat`、`fix`、`docs`、`style`、`refactor`、`perf`、`test`、`chore`、`build`、`ci` 和 `revert`。

- **PR 正文**必须是英文，并包含 `.github/PULL_REQUEST_TEMPLATE.md` 提供的 `Summary`、`GitHub Project`、`PR Type`、`Validation`、`Risk and Rollback`、`Related Issue` 和 `AI Attribution` 各节。
  - `GitHub Project` 保留模板里的 `- Project: zshell Development`。`Project Automation` 读取它把 Pull Request 放到共享看板上。
  - `PR Type` 只声明一个 `- Type:` 值，且必须与标题里的类型一致。`PR Automation` 会把它转成标签，例如 `fix` 转成 `bug`。
  - 每个 `Validation` 块都要声明 `passed`、`failed` 或 `not run`。`passed` 和 `failed` 需要 `Command` 和 `Result`；`not run` 需要 `Reason`。
  - `Related Issue` 要么用 `Closes #123` 这类关键字关闭某个 Issue（这也会打上 `development` 标签），要么就写成 `None`。
  - `AI Attribution` 必须声明 `- Agent:`。除 `None` 以外的任何 agent 都需要一行对应的 `- Co-authored-by: Name <email>`，并且它必须同时作为 trailer 出现在至少一个提交里，这会打上 `ai-assisted` 标签。

  示例：

  ```markdown
  ## Summary
  - Add a repository hygiene check.

  ## GitHub Project
  - Project: zshell Development

  ## PR Type
  - Type: ci

  ## Validation
  - Status: passed
  - Command: bash .github/scripts/check-repository-hygiene.sh
  - Result: Repository hygiene check passed.

  ## Risk and Rollback
  - Risk: Only repository automation is affected.
  - Rollback: Revert this pull request.

  ## Related Issue
  Closes #123

  ## AI Attribution
  - Agent: Claude Code
  - Co-authored-by: Claude <noreply@anthropic.com>
  ```

- `PR Quality` 检查会校验这个格式；检查失败时 Pull Request 无法合并。随后 `PR Automation` 会打标签并指派 Pull Request。
- 项目没有单元测试 target：应用改动靠构建、运行 Zshell 并实际操作来证明，所以请在 `Validation` 里写清楚你做了什么，UI 改动请附截图或录屏。桥接层改动请在 `mac/Vendor/alacritty-bridge` 运行 `cargo test --locked`，站点改动请在 `web/` 运行 `bun run typecheck && bun run build`，`mac/scripts/` 下的改动请在 `mac/` 运行 `bunx tsc --noEmit`。运行 Bun 检查前先在各自的包里用 `bun install --frozen-lockfile` 安装依赖。
- 所有新 UI 都用 AppKit 写。SwiftUI 属于遗留代码，不得引入也不得扩大；对现有 SwiftUI 视图做实质性修改时，要把受影响的 UI 迁移到 AppKit。
- 改变用户可见行为、构建说明或发布流程时，请同步更新相关文档。[CHANGELOG.md](CHANGELOG.md) 是写给最终用户的，因此只记录最终交付的结果，而不是过程中的修复和重构；版本号只由发布流程提升，绝不在 Pull Request 里改。
- 不要提交 `mac/build/`、`mac/Vendor/alacritty-bridge/target`、`node_modules`、`dist`、下载的文件、日志、token、签名材料或个人数据。`Repository Hygiene` 会因此失败。
- `main` 和 `publish-v*` 受保护，只能通过经过评审且检查通过的 Pull Request 更新。

## 跳过 CI

维护者和被请求的评审者可以跳过某个改动不可能影响到的检查，例如纯文档修复。把指令
单独写成 Pull Request 评论中的一行：

| 指令 | 效果 |
| --- | --- |
| `skip-all` | 跳过 `.github/ci-skip.json` 中列出的所有工作流。 |
| `skip-<workflow>` | 按名称、文件名或别名跳过单个工作流，例如 `skip-mac`、`skip-web-ci` 或 `skip-Web CI`。 |
| `unskip-all` | 清除所有跳过指令。 |
| `unskip-<workflow>` | 恢复单个工作流。 |

- 指令后面可以跟自由文本，例如 `skip-all: documentation only change`。
- 工作流可以按 GitHub 显示的名字来写，含空格也可以，所以 `skip-Repository Hygiene` 和 `skip-hygiene` 是同一条指令。匹配到的最长名字胜出，剩下的词作为备注。
- 只有仓库所有者、组织成员、协作者或被请求的评审者的指令才被采纳。机器人评论会被忽略。
- `CI Skip` 会取消正在运行的 run，把被跳过的检查报告为成功以满足必需检查，打上 `skip-ci` 标签，并把当前决定写进同一条汇总评论。
- 每次有新评论都会重放整个评论线程，所以最新的指令总是生效的那条。
- 一旦推送了更新的提交，指令立即失效：它只能对作者当时看到的代码负责，否则一个被报告为成功的检查会让新提交在未构建的情况下合并。`CI Skip` 会在每次推送时重新运行，摘掉 `skip-ci` 标签并恢复检查，汇总评论会列出已失效的指令。想跳过新提交，请再评论一次指令。
- 维护者无需新评论也可以重新应用当前决定：**Actions -> CI Skip -> Run workflow**，传入 Pull Request 编号。
- `.github/ci-skip.json` 把每个工作流映射到它发布的检查名。清单与工作流文件不一致时 `Test CI Scripts` 会失败。

## 按路径生效的检查

平台相关的工作流只在 Pull Request 触及它构建的文件时才运行，所以文档改动不会启动
macOS runner：

| 工作流 | 在 Pull Request 触及这些路径时运行 |
| --- | --- |
| `macOS App` | `mac/zshell/**`、`mac/zshell.xcodeproj/**`、`mac/Vendor/**`、`mac/Config/**`、`mac/Makefile`、`Makefile`、`mac/scripts/build-alacritty-bridge.sh`、`.github/**` |
| `Release Scripts` | `mac/scripts/**`、`mac/package.json`、`mac/bun.lock`、`mac/tsconfig.json`、`.github/**` |
| `Web CI` | `web/**`、`.github/**` |
| `Skill CI` | `skills/**`、`mac/zshell/Skills/**`、`.github/**` |

- 范围由 `.github/ci-skip.json` 的 `paths` 字段决定，没有声明 paths 的工作流总是运行。因此 `CI Lint`、`Repository Hygiene`、`PR Quality Gates`、`CodeQL` 和 `Dependency Review` 在每个 Pull Request 上都会跑。
- `mac/scripts/build-alacritty-bridge.sh` 被两个工作流同时认领是刻意的：它位于 `mac/scripts/` 下，同时也是产出 Alacritty 后端静态库的那个 Xcode 构建阶段。
- `.github/` 下的任何改动都会触发全部检查，因为改 CI 必须在每个平台上验证。
- 这些 job 是用 job 条件跳过的，而不是工作流的 `paths:` 过滤器，这样必需检查会报告成功，而不是永远挂在 pending。
- 文件重命名时新旧路径都会参与匹配，且比较时忽略大小写。
