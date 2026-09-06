---
name: zshell-release
description: Zshell 正式 macOS 发布工作流：固定自签名证书、Sparkle Ed25519、arm64/x86_64/Universal 三套包、GitHub 和 Gitee 双端发布与验证。正式发布需要用户明确授权。
---

# Zshell 正式发布

以 [mac/RELEASING.md](../../mac/RELEASING.md) 为命令、资产命名和凭据的权威说明。
当前流程发布 macOS Release 的三种架构，不提供 Preview、Windows 或 Linux 发版。

## 授权与密钥

- 用户明确要求发版后，完成构建、双端上传和验证；同一次发版不重复索要授权。
- 默认使用固定 **zshell Release Signing** 自签名证书，未经 Apple 公证，不再用 ad-hoc 正式签名。
- 代码签名身份独立于 Sparkle Ed25519 更新密钥。沿用现有 Zshell 更新私钥，校验它与
  `SUPublicEDKey` 匹配；禁止复用 Zisla 私钥或为绕过失败而更换公钥。
- 一次性代码签名初始化只在已有发版/签名授权内执行。使用用户指定的私有目录备份加密 PEM
  私钥、PEM 证书、P12，权限 `600`。已有身份要恢复和复用，不能默默重建。
- 私钥、令牌、Keychain 密码和用户私人绝对路径不能出现在终端日志、PR 或 Release 正文中。
- 构建号每次正式发版递增，普通功能 PR 不改版本；已发布资产不可静默换成另一份构建。
- tap 和官网修改提 PR 交用户合并；发布脚本不直接推 tap 主分支、不自动部署官网。

## 执行

1. 先读 [preflight](references/preflight.md)，核对工具、已有签名身份、版本、双端权限。
2. 使用同一已提交源码生成 `arm64`、`x86_64`、`universal` 三套 DMG/ZIP，分别写 SHA-256。
3. 各架构 app 的全部 Mach-O 都须符合目标架构，嵌套代码签名完整，三个包使用同一稳定
   designated requirement，包含 Sparkle installer 和正式版白底图标。
4. 为 GitHub 和 Gitee 各生成三份完整签名 appcast。每份恰好一个条目，ZIP 链接属于本站、
   本版本、本架构，并有 enclosure Ed25519 签名。`SURequireSignedFeed` 必须启用。
5. 两端版本 Release 各上传 15 份必需资产；Gitee 永久 `update-release` 仅放三份 appcast。
   先上传和验证两端包，再切 feed；Gitee 永久 feed 必须早于实际版本 Release 创建。
6. 验证双端资产哈希和六份匿名 feed；官网提供 Universal 主下载、Apple Silicon、Intel 和镜像入口。
7. 更新 tap 的本机架构 ZIP URL、两个 SHA-256、最低系统版本，并与官网一起交 PR。

从 `mac/` 执行：

```sh
SPARKLE_ED_KEY_FILE=/path/to/zshell-update-key bun scripts/release.ts --local
# 同源 archive 恢复打包：
SPARKLE_ED_KEY_FILE=/path/to/zshell-update-key bun scripts/release.ts --local --package-only
# 发布/复核已验证的本地包：
bun scripts/publish-release.ts --publish build/release-v<version> <version> <source-commit>
bun scripts/publish-release.ts --verify build/release-v<version> <version> <source-commit>
```

`--local` 也生成完整 ZIP 和签名 feed，仅跳过联网发布。去掉 `--local` 即构建后双端发布。
`--package-only` 只接受当前源码 commit 的 archive。可设置 `BUILD_JOBS=2` 与
`RELEASE_OUTPUT_DIRECTORY`；不要继续使用旧流程的 `FORCE`、`NO_TAP`、`NO_SITE` 等开关。

## 更新验收

- Gitee 主 feed：`releases/download/update-release/appcast.xml`。
- GitHub fallback：`releases/latest/download/appcast.xml`。
- 单架构 feed 为 `appcast-arm64.xml` / `appcast-x86_64.xml`，Universal 为 `appcast.xml`。
- 直接安装和 Homebrew 安装均由 Sparkle 更新。Homebrew 仅保留显式命令或落后版本兜底。
- 旧版正式测试实例必须走真实签名 feed、下载、验签、替换、重启；主 feed 或下载失败仅重试
  GitHub 一次。测试 thin 保留架构、Universal 保留双架构、Rosetta Intel 迁移 arm64。
- 签名字段存在、单元测试通过、Debug 能运行都不能替代真实升级验收。没有旧版测试机时如实
  标注未验证范围，不宣称全部对齐验收完成。
- 此次 0.1.0 从旧 ad-hoc build 2 迁移到固定自签名 build 3；保留旧下载名、原更新私钥和旧
  `updates` feed 的可用性，不破坏已安装版本。

## 验证与清理

按实际改动运行脚本测试、客户端验证与官网 build/typecheck。Release 正文写清签名、公证、
架构、实测系统范围和首次打开步骤；反馈入口指向 GitHub，Gitee 作为发版镜像。
正文截图若存在，必须为本次 tag 的稳定附件 URL，逐一核对 HTTP 200 与真实 PNG 字节。

失败先按 [troubleshooting](references/troubleshooting.md) 确认线上已生效步骤，从同一份本地产物
恢复，不能盲目重新打包覆盖。完成后只清本次构建、binary、挂载、测试实例和临时下载，保留
用户指定交付文件、签名备份与其他任务的 Debug 产物。
