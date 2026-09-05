---
name: zshell-release
description: Zshell 的 macOS 发布与 Sparkle 自动更新工作流。在打本地签名包、切正式版本、核对发布前置条件，或排查公证、appcast、Cloudflare R2、Homebrew cask、站点重建失败时使用。单通道单 bucket，每版两个产物；正式发布必须先有用户明确授权。
---

# Zshell 发布

一条命令走完：archive → Developer ID 导出 → 公证并 staple → DMG 与 Sparkle zip →
签名并重写 appcast → 上传 Cloudflare R2 → bump Homebrew cask → 触发站点重建。
分发源是 `https://releases.zshell.sh`，feed 是同源的 `appcast.xml`。
单个 Sparkle feed、单 bucket；下载用 `.dmg`，Sparkle 更新用 `.zip`，有历史归档时另生成增量。
当前 `Updater.swift` 检测到 Homebrew 的 `Caskroom/zshell` 和可执行 `brew` 时，正式版改用
`brew upgrade --cask zshell`；核对更新行为时先确认走的是 Homebrew 还是 Sparkle。

## 授权边界（先看）

- **正式发布必须有用户明确授权。** 只写 skill、只读脚本、只核对前置条件时，
  绝不执行发布、绝不改版本号、绝不生成或轮换任何密钥。
- 用户已授权本次发布后，不要为同一次发布反复索要授权。
- 除非用户明确要求迁移更新配置或签名，否则不改 `mac/zshell/Info.plist` 的 `SUFeedURL` / `SUPublicEDKey`，不重新生成 Sparkle 私钥，
  不动 keychain 凭据。公钥与私钥一旦不匹配，现有用户能看到更新但装不上（签名校验失败）。
- 版本号只由发布流程推进，任何 PR 都不许 bump。`mac/RELEASING.md` 是 maintainer-only 流程。

## 本地打包（不发布）

```sh
make build-package
```

委派到 `mac/scripts/release.ts --local`：archive、导出 Developer ID 应用、造 DMG 并用
Developer ID 签名，然后停下——**不公证、不上传、不动 cask 与站点**。产物在
`mac/build/export/zshell.app` 与 `mac/build/zshell-<version>.dmg`。
用它验证签名与打包，不能用它验证更新流程。

## 正式发布

```sh
cd mac && bun run release        # 等价于 bun scripts/release.ts
```

默认会公证、上传 R2、bump `wzz6423/homebrew-tap` 的 `Casks/zshell.rb`、
`gh workflow run "Web Pages" --ref main`。

### 发布前

1. 版本号在 `mac/zshell.xcodeproj` 的 `zshell` target：`MARKETING_VERSION`（用户可见）
   与 `CURRENT_PROJECT_VERSION`（构建号，**每次发布必须递增**，Sparkle 靠它判断新旧）。
2. 仓库根 `CHANGELOG.md` 顶部加 `## [<MARKETING_VERSION>]` 小节，标题里的版本必须与
   `MARKETING_VERSION` 完全一致；不一致就会静默地"发布但没有 release notes"。
3. 用 [references/preflight.md](references/preflight.md) 逐项核对工具链与凭据，全是只读命令。
   缺任何一项就停下报告，不要临时改默认值绕开。

### 常用开关

| 开关 | 用途 |
| --- | --- |
| `FORCE=1` | 重发已存在的版本；默认会因 R2 已有同名 zip 而中止 |
| `NO_TAP=1` | 跳过 Homebrew cask bump |
| `NO_SITE=1` | 跳过站点重建 |
| `NO_HISTORY=1` | 不拉历史归档，本次不生成增量，用户下整包 |
| `HISTORY_COUNT=<n>` | 参与增量的历史归档数，默认 15 |
| `BUILD_JOBS=2`、`BUILD_NICE=1` | 限制 archive 并发 / 降到 utility QoS，保持机器可用 |

完整环境变量表和一次性设置（Sparkle 密钥、公证 profile、R2 与 rclone、tap SSH）
在 `mac/RELEASING.md`，不要在这里重复维护。

### 脚本实际做的事

按序：校验所需命令与 `mac/scripts/ExportOptions.plist` 存在 → archive（`-jobs`，
可选 `taskpolicy -c utility`）→ `-exportArchive` 出 Developer ID 应用 → 从产物 `Info.plist`
读 `CFBundleShortVersionString` / `CFBundleVersion` → 查 R2 是否已有同名 zip →
造 DMG 并签名（`--local` 到此结束）→ 公证 DMG，再 staple DMG 和 app（一次提交覆盖两者）→
拉最近历史归档、打 `zshell-<version>.zip`、从根 `CHANGELOG.md` 切出 `zshell-<version>.md` →
用 keychain 私钥签名并重写 `appcast.xml` → 上传（归档与 DMG 长缓存 immutable，
appcast 短缓存 must-revalidate）→ bump cask → 触发 `Web Pages`。

`create-dmg` 会因 Finder 脚本的无害抖动返回非零，脚本因此只判断文件是否生成，不看退出码。

## 发布后验证

```sh
curl --fail --head "https://releases.zshell.sh/zshell-<version>.dmg"
curl --fail --silent --show-error "https://releases.zshell.sh/appcast.xml"
```

将 `<version>` 替换为本次版本。验证 feed 的 XML、版本、构建号、ZIP URL、长度和 EdDSA
签名字段，并确认它引用的 ZIP 可下载；签名字段存在并不等于已验证安装验签。
在走 Sparkle 的**旧版本**测试安装中实际运行 **Check for Updates…**，确认验签、安装和重启。
Homebrew 路径另验 cask 更新。Debug 构建不启动 Sparkle，不能替代更新验收。
然后确认 cask 的 `version` 与 `sha256` 已更新，站点下载按钮指向新版本——站点在预渲染时把
版本烤进页面，只有 `Web Pages` 跑完才会变。

## 失败恢复

cask bump 与站点重建都在上传之后，脚本把它们的失败降级为告警：发布本身已经生效，
只补这一步即可。

```sh
(cd mac && bun scripts/bump-cask.ts "<version>")     # build/ 里没有 DMG 就下载已发布的再算 sha
gh workflow run "Web Pages" --ref main
```

archive、DMG、公证这些步骤可以整条重跑。**一旦 zip 已经上传 R2，重跑需要 `FORCE=1`**，
执行前先确认要覆盖的是同一份构建，否则同一版本号会对应两份不同二进制。
其余症状按 [references/troubleshooting.md](references/troubleshooting.md) 对症处理。

`depends_on macos:` 与 app 的 `LSMinimumSystemVersion` 漂移时脚本只告警，
需要手工改 tap 里那条 stanza；bump 脚本不会碰它。

## 清理

确认本次发布完成且无需失败恢复后，仅删除本次在 `mac/build/` 生成的 `zshell.xcarchive`、`export/`、`dmg/`、`updates/`、
`homebrew-tap/` 与 `zshell-*.dmg`。保留用户指定交付的安装包；测试包必须清理。
`make clean` 还会停止 Debug 应用并删除共享产物，只在用户要求整体清理或确认没有其他任务使用时运行。
导出的 Sparkle 私钥、签名材料、下载下来的旧归档一律不许进仓库。
