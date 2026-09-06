# 发布故障恢复

先确认哪一步已在线上生效。保留本次验证过的产物，从失败步骤恢复；不要因为网络失败重新
编译并覆盖同名版本包。使用 `publish-release.ts --verify` 获取双端缺失/哈希不符的证据。

| 现象 | 处理 |
| --- | --- |
| Release signing keychain 缺失 | 已存在备份时恢复原 `zshell Release Signing` 身份；首次设置按 `mac/RELEASING.md` 执行。不要直接换成 ad-hoc。 |
| Sparkle key 与公钥不匹配 | 确认 `SPARKLE_ED_KEY_FILE` 是原 Zshell key，权限 `600`。不换公钥，不借用 Zisla 私钥。 |
| `generate_appcast` / `sign_update` 缺失 | 设置 `SPARKLE_BIN` 指向已安装的 Sparkle bin。 |
| x86_64 Rust 编译失败 | 检查当前 Rust toolchain 有 `x86_64-apple-darwin` 和 `aarch64-apple-darwin`，不要只看宿主 arm64 target。 |
| 目标架构或签名不符 | 修复 archive/裁剪/嵌套签名问题后，重新生成三套完整资产；不把单个错误包上传到有效 feed。 |
| archive 已存在 | 同 source commit 用 `--package-only`；源码变化则使用新的 `RELEASE_OUTPUT_DIRECTORY`。 |
| GitHub 或 Gitee 认证失败 | 修复对应凭据或仓库权限；不要在日志打印 token，不因一端成功跳过另一端。 |
| 上传中断或重复文件名 | 用相同产物重新执行 `publish-release.ts --publish`，发布器比对 SHA-256 后只补缺失或不同资产。 |
| ZIP 已上线但 feed 未更新 | 先验证两端完整包，再上传与这些 ZIP 对应的三份本站签名 feed；不要单独手改签名后的 XML。 |
| Gitee latest 指向永久 feed | `update-release` 创建晚于版本 Release。先保留完整资产与证据；修正创建顺序需要明确处理已有发布，单纯 PATCH 不会改变顺序。 |
| 官网仍显示旧版本 | 官网预渲染缓存了构建时的 feed；先确认官网 PR 已合并和 `Web Pages` 成功，再核对匿名下载链接。 |
| Homebrew 版本落后 | 更新 tap PR 的版本和本机架构 ZIP 校验值；不要直接跑旧 `bump-cask.ts` 去推 main。 |
| 旧 ad-hoc 0.1.0 无法升级 | 保留原 Sparkle Ed25519 key 和旧 `updates` feed；用真实旧版验证到新 build 的迁移，不能只测试新版本自己的主/fallback feed。 |

恢复命令（从 `mac/`）：

```sh
bun scripts/publish-release.ts --publish build/release-v<version> <version> <source-commit>
bun scripts/publish-release.ts --verify build/release-v<version> <version> <source-commit>
```

任一公开 feed 无法读取、签名不符或指错架构，都不算发版完成。若测试机或网络阻塞无法消除，
明确记录已发布部分和未验证部分。清理只针对本次任务产生的测试包、挂载点、临时文件和
archive；不清私钥备份，不停止用户或其他任务的 Debug 实例。
