# 发布故障排查

按发布脚本的步骤顺序排列。除标注外，处理办法都不涉及改脚本默认值或凭据。

## 前置检查阶段

| 现象 | 原因与处理 |
| --- | --- |
| `error: missing required tool: create-dmg` / `rclone` / `gh` | `brew install create-dmg rclone gh`；`gh` 只有在没设 `NO_SITE=1` 时才需要 |
| `error: export options not found: scripts/ExportOptions.plist` | 脚本会先 `chdir` 到 `mac/`，路径相对 `mac/`；文件应在 `mac/scripts/ExportOptions.plist` |
| `error: HISTORY_COUNT must be …` / `BUILD_JOBS must be …` | 传了非法值，改回整数 |

## archive 与导出

| 现象 | 原因与处理 |
| --- | --- |
| archive 把机器压满 | `BUILD_JOBS=2 BUILD_NICE=1 bun run release`；Release 用 whole-module 优化，单个 `swift-frontend` 也会吃多核 |
| `No signing certificate "Developer ID Application"` | 证书没装进 login keychain；多张同类证书时用 `SIGN_IDENTITY` 指定全名或 SHA-1 |
| 导出报 team 不匹配 | `mac/scripts/ExportOptions.plist` 的 `teamID` 与证书不是同一个 team |
| `exported app not found at build/export/zshell.app` | 导出方式不是 `developer-id`，或 archive 里没有 `zshell` 产物 |
| 缺 Rust target / cargo | 桥的构建阶段失败，见 `skills/zshell-app-development/references/architecture.md` |

## DMG 与公证

| 现象 | 原因与处理 |
| --- | --- |
| `create-dmg` 退出码非零但 DMG 存在 | 先读错误：Finder 脚本可能造成非零退出。文件存在只是脚本继续的条件，还需校验磁盘映像与应用，不能据此判定成功 |
| `create-dmg did not produce a disk image` | 磁盘映像真的没造出来；先确认 `mac/build/dmg` 暂存目录可写、磁盘空间够 |
| 公证返回 `Invalid` | 取详细原因：`xcrun notarytool log <submission-id> --keychain-profile NOTARY`。常见是 Hardened Runtime 或签名缺失，工程已开 Hardened Runtime，先查新加入的二进制/framework 是否签了 |
| 公证卡住很久 | `--wait` 就是在等 Apple 返回；不要中断后立刻重跑，先用 `notarytool history` 看这次提交的状态 |
| `stapler staple` 失败 | 票据还没生效，稍后重试同一命令即可，不必重打包 |

## 版本冲突与增量

| 现象 | 原因与处理 |
| --- | --- |
| `zshell-<v>.zip already exists in R2 — bump the version, or set FORCE=1.` | 该版本已发布。正常做法是 bump 版本；确实要覆盖必须先得到用户同意，再 `FORCE=1`，并确认覆盖的是同一份构建 |
| 本次没有生成增量 | 没拉到历史归档：设了 `NO_HISTORY=1`、bucket 里还没有旧 zip，或 `HISTORY_COUNT=0`。首次发布本来就没有增量 |
| 用户看不到新版本 | `CURRENT_PROJECT_VERSION` 没递增（Sparkle 只比这个）；或 appcast 还在缓存窗口内（上传时用 `max-age=300, must-revalidate`），等一会儿再试 |
| 更新能看到但装不上，报签名校验失败 | `mac/zshell/Info.plist` 的 `SUPublicEDKey` 与签 appcast 的私钥不匹配。不要改公钥去凑，先确认用的是哪个 keychain 账户（默认 `zshell-update-ed25519`） |
| 发布了但没有 release notes | 根 `CHANGELOG.md` 里没有与 `MARKETING_VERSION` 完全一致的 `## [x.y]` 小节。补上小节后重跑发布（需 `FORCE=1`），或只补 notes 文件与 appcast 后重新上传 |

## appcast 生成

| 现象 | 原因与处理 |
| --- | --- |
| `generate_appcast not found` | 设 `SPARKLE_BIN=/path/to/Sparkle/bin`，或把它放进 `PATH`；也可从 Xcode DerivedData 里的 Sparkle artifacts 取 |
| `generate_appcast` 报找不到私钥 | keychain 里没有 `SPARKLE_KEY_ACCOUNT`（默认 `zshell-update-ed25519`）对应的项；在这台机器上用 `generate_keys -f` 导入备份，不要重新生成 |
| 只想重做 appcast | `cd mac && bun run appcast build/updates`，然后单独把 `appcast.xml` 上传回 R2 |

## 上传

| 现象 | 原因与处理 |
| --- | --- |
| rclone 报 bucket 相关权限错误 | token 是 bucket 作用域，建不了 bucket；确认远端配置有 `no_check_bucket = true`，脚本已传 `--s3-no-check-bucket` |
| `directory not found` / 远端为空 | 远端名或 bucket 名不对，核对 `R2_REMOTE`（默认 `r2`）与 `R2_BUCKET`（默认 `zshell-releases`） |
| 上传中断 | 归档与 DMG 是不可变对象，重跑上传是幂等的；zip 已上传后整条重跑需要 `FORCE=1` |

## cask 与站点（上传之后，失败只是告警）

| 现象 | 原因与处理 |
| --- | --- |
| `could not bump the cask` | 单独重试 `cd mac && bun scripts/bump-cask.ts <version>`；它会在本地没有 DMG 时下载已发布的那份再算 sha |
| tap 推送被拒 | 需要对 tap 的 SSH 推送权限；脚本会把本地 checkout `reset --hard origin/main`，不要在 `mac/build/homebrew-tap` 里留手工提交 |
| `could not find version/sha256 stanzas` | cask 结构变了，手工改 `Casks/zshell.rb` |
| 警告说 app 需要的 macOS 版本与 cask 的 `depends_on macos:` 不一致 | bump 脚本不改这条 stanza，手工改 tap |
| 站点还显示旧版本 | `Web Pages` 没跑成功；`gh workflow run "Web Pages" --ref main` 重触发。站点在预渲染时把版本烤进页面，appcast 更新不会自动反映到页面 |
| cask 已是该版本 | bump 是幂等的，直接报"已在该版本"并返回，不是错误 |

## 收尾

发布中断在任何一步之后，先判断"是否已经上传 zip / appcast"：已上传就意味着用户可能已经拿到更新，
后续动作要按线上已生效处理，不要静默覆盖。恢复完成后清理本次测试和临时产物，保留用户要求交付的安装包；不要删除其他任务的构建目录。
