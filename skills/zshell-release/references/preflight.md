# 发布前置检查

先只读核对；缺失项在已有授权范围内补齐，不通过临时改默认身份或换私钥绕过检查。

## 工具与源码

在仓库根执行：

```sh
command -v xcodebuild xcrun ditto plutil bun gh codesign git security lipo hdiutil xmllint
xcodebuild -version
rustup target list --installed
git status --short
rg -n 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' mac/zshell.xcodeproj/project.pbxproj
rg -n '^## ' CHANGELOG.md
```

Rust 需要 `aarch64-apple-darwin` 和 `x86_64-apple-darwin` 两个 target。保持 vendored
依赖固定；不要运行更新依赖来解决发版问题。版本、构建号、CHANGELOG 必须一致，源码 commit
必须在两端可访问。`--package-only` 还必须匹配 archive 记录的 source commit。

## 签名

```sh
test -f "$HOME/Library/Keychains/zshell-release-signing.keychain-db"
security find-certificate -c 'zshell Release Signing' "$HOME/Library/Keychains/zshell-release-signing.keychain-db" > /dev/null
security find-generic-password -s sh.zshell.release-signing-keychain > /dev/null
plutil -extract SUPublicEDKey raw mac/zshell/Info.plist
plutil -extract SURequireSignedFeed raw mac/zshell/Info.plist
plutil -extract SUFeedURL raw mac/zshell/Info.plist
plutil -extract ZshellReleaseFallbackAppcastURL raw mac/zshell/Info.plist
```

不要给 Keychain 查询加 `-w` 或 `-g` 将秘密输出到日志。代码签名证书是固定自签名身份，
不要求 Developer ID、公证 profile 或 `ExportOptions.plist`。
`SPARKLE_ED_KEY_FILE` 必须指向已有 Zshell 私钥，权限 `600`；脚本会在读取后仅报告公私钥
是否匹配，不打印密钥。`SPARKLE_BIN` 可指定含 `generate_appcast` 和 `sign_update` 的目录。

## 双端权限与已有发布

```sh
gh auth status
gh release view v<version> --repo wzz6423/zshell --json tagName,isDraft,isPrerelease,assets
```

首次版本不存在是正常情况。Gitee 的 token 由 `GITEE_RELEASE_TOKEN` 或现有 Keychain
项私下读取。发布器的 preflight 验证两端账号、公开仓库、写权限和 source commit，不回显
token。不能把“GitHub 发布成功”当成 Gitee 已同步。

已有同版本资产先比对 hash。确认 Gitee 永久 `update-release` 的创建顺序早于实际版本
Release；否则不能只 PATCH 版本信息后宣称 latest 徽章已修复。

## 发布完成的判断

- 两端各三套 DMG、ZIP 和对应 `.sha256`，共 12 个文件，外加三份已签名 appcast。
- Gitee 永久 feed 只有三份 appcast。六份公开 feed 均可匿名读取并通过真实 Ed25519 校验。
- 每份 feed 恰好一个 item，版本、构建号、站点、ZIP 架构、length 与本地产物一致。
- 下载 ZIP 和挂载 DMG 后签名与架构检查成功；旧版 Sparkle 安装测试结果如实记录。
- tap PR、官网 PR 与线上版本一致，用户合并后再确认安装和官网入口。
