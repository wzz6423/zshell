# Zshell 项目长期备忘

## 环境硬约束（WorkBuddy 会话内）

- xcodebuild 不可运行：SwiftPM 嵌套沙箱 `sandbox_apply: EPERM`（disableSandbox 亦然），launchctl IPC 也被挡。编译验证替代方案：实现会话的构建报告 + `swiftc -parse` + `xcstringstool compile --dry-run` + `git diff --check`。
- git HTTPS 被代理拦（CONNECT 502）；推送走 SSH：`git push git@github.com:wzz6423/zshell.git <br>:<br>`。`gh` 可用，PR 用 `--head wzz6423:<branch>`。
- 用户的 Claude CLI 额度可能为负（403 用户额度不足），`claude agents` 任务会话会集体 blocked。

## 构建验证标准命令

- xcodebuild 在 WorkBuddy 会话内不可运行（SwiftPM 嵌套沙箱 EPERM），替代方案：实现会话构建报告 + `swiftc -parse` + `xcrun xcstringstool compile <xcstrings> --output-directory <tmpdir> --dry-run`（必须带 --output-directory）+ `git diff --check` + `git merge-tree --write-tree`。
- 本地 main 可能落后于远程且工作区停在旧分支：一律 `git fetch git@github.com:wzz6423/zshell.git main:main --force`（SSH），验证前先 checkout main。
- xcstrings 冲突 union 合并脚本必须用 `os.path.join(repo, path)` 定位输出（相对路径会写歪到 cwd）；多提交分支 rebase 卡 JSON 时改用 squash 重建。
- PR 合并循环：SSH fetch main+分支 → `git merge-tree --write-tree` 预检 → `gh pr merge <N> --repo wzz6423/zshell --squash --delete-branch --admin`（CI 被绕过需 --admin，用户已授权此模式）。合并会推进 main 使其余分支再冲突，需多轮收敛。

## 项目工作流

- Kero 功能收口模式：编排会话（Claude Code）为每个缺口建 `.claude/worktrees/<名>` + 任务会话（实现不提交），验证后由编排方提交推送开 PR（conventional commits 英文标题 + 固定 PR 模板，含 Summary / GitHub Project: zshell Development / PR Type / Validation / Risk and Rollback）。
- 构建验证标准命令：`xcodebuild -project mac/zshell.xcodeproj -scheme zshell -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath <tmp> CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`（仅用户本机可用）；本地化校验必须带输出目录 `xcrun xcstringstool compile mac/zshell/Localizable.xcstrings --output-directory <tmp> --dry-run`。
- 任务会话转录：`~/.claude/projects/-Users-wzz----code-zshell--claude-worktrees-<名>/<sessionId>.jsonl`。
