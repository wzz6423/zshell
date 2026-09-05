# 发布前置条件核对（全部只读）

按顺序执行，任一项不通过就停下报告，不要改脚本默认值绕开。
在仓库根执行；标注"联网"的会访问网络但不写入任何东西。

## 1. 工具链

```sh
for t in xcodebuild xcrun ditto plutil bun create-dmg gh codesign git security; do
  printf '%-12s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
done
```

`create-dmg` 与 `gh` 来自 Homebrew（`brew install create-dmg gh`）。
`--local` 跳过公证和发布，不需要 gh 登录或公证凭据。
正式发布必须有 git 和已登录的 gh：发布本身要靠 gh 建 release，`NO_TAP=1` / `NO_SITE=1`
只跳过 cask bump 与站点重建。

Sparkle 的 `generate_appcast` 按 `SPARKLE_BIN` → `PATH` →
`~/Library/Developer/Xcode/DerivedData/*/artifacts/*/Sparkle/bin/` 的顺序查找：

```sh
test -n "${SPARKLE_BIN:-}" && test -x "$SPARKLE_BIN/generate_appcast" || \
  command -v generate_appcast || \
  find ~/Library/Developer/Xcode/DerivedData \
    -path '*/artifacts/*/Sparkle/bin/generate_appcast' -type f 2>/dev/null | head -1
```

找不到就设 `SPARKLE_BIN=/path/to/Sparkle/bin`，不要改脚本。

## 2. 签名与公证凭据

```sh
security find-identity -v -p codesigning | grep 'Developer ID Application'
plutil -extract teamID raw mac/scripts/ExportOptions.plist
security find-generic-password -a zshell-update-ed25519 > /dev/null && echo 'sparkle key: present'
xcrun notarytool history --keychain-profile NOTARY | head -5   # 联网
```

- `ExportOptions.plist` 的 `teamID` 必须是那张 Developer ID 证书的 team。
- 查 Sparkle 私钥时**不要**加 `-g` / `-w`，那会把私钥打印出来。
- `notarytool history` 报 profile 不存在，说明还没 `xcrun notarytool store-credentials NOTARY`，
  按 `mac/RELEASING.md` 做一次性设置，不要在发布命令里现编凭据。

## 3. 发布与 tap 访问

```sh
gh auth status                                                      # 联网
gh release view updates --repo wzz6423/zshell --json assets --jq '.assets[].name' | tail -5   # 联网
git ls-remote --heads git@github.com:wzz6423/homebrew-tap.git refs/heads/main   # 联网
```

发布仓库默认 `wzz6423/zshell`（`RELEASE_REPO`），归档与 feed 所在的常驻 release 默认
tag `updates`（`UPDATES_TAG`）。第二条在首次发布前会报 release 不存在，属正常。

## 4. 版本与 release notes

```sh
grep -nE 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' mac/zshell.xcodeproj/project.pbxproj
grep -n '^## ' CHANGELOG.md | head -3
```

只读检查直接读取工程文件和已存在的 Release 产物。`xcodebuild -showBuildSettings`
也可能解析依赖、下载包并改写 `Package.resolved`，不把它列为无副作用检查。
需要评估最终构建设置时，在临时副本中使用固定依赖版本，并在结束后清理副本。

核对三件事：

1. `CURRENT_PROJECT_VERSION` 比上一版大——Sparkle 只看它判断新旧。
2. `CHANGELOG.md` 最上面那个 `## [x.y]` 的版本与 `MARKETING_VERSION` 完全一致。
3. 该版本尚未发布过：

```sh
gh release view updates --repo wzz6423/zshell --json assets --jq '.assets[].name' | grep -x 'zshell-<version>.zip'   # 联网
```

有输出说明已发布，需要用户明确同意才可 `FORCE=1` 覆盖。

## 5. 更新配置未被改动

```sh
plutil -extract SUFeedURL raw mac/zshell/Info.plist
plutil -extract SUPublicEDKey raw mac/zshell/Info.plist
git -C . diff --stat -- mac/zshell/Info.plist
```

feed 应为 `https://github.com/wzz6423/zshell/releases/download/updates/appcast.xml`。
`SUPublicEDKey` 有未提交改动就先停下问用户：它必须与签 appcast 的私钥配对，
改错会让现有用户装不上更新。
