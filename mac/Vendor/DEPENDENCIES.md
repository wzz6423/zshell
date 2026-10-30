# 固定第三方依赖

macOS 应用使用本目录内的第三方源码和 XCFramework。普通构建不会从远程仓库解析或下载依赖；升级依赖时，单独更新对应目录、核对版本和许可证后再提交。

| 依赖 | 固定版本 / revision | 本地目录 |
| --- | --- | --- |
| GhosttyKit | storage.1.3.7 + macOS command records（上游 `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`） | `libghostty-spm/GhosttyKit.xcframework` |
| alacritty_terminal | 0.26.0 + 本地 OSC 7/133 与命令锚点 | `alacritty-bridge/src/alacritty_terminal` |
| vte | 0.15.0 + 本地 OSC 回调 | `alacritty-bridge/src/vte` |
| Sparkle | 2.9.4 | `Sparkle/Sparkle.xcframework` |
| swift-markdown | `27b7fc1a19068bcea3d2072db0ce86360d1400ed` | `swift-markdown` |
| swift-cmark | gfm 分支 / `7898f1b3e4befeecee56cb4a3bc8eebd2cb63219` | `swift-cmark` |
| PierreDiffsSwift | 1.5.0 / `3713d29360b750d3d6146b187ff3b77b7d498fee` | `PierreDiffsSwift` |
| FuzzyMatch | 1.4.0 / `ea09aa7faa3c1832716d1ccdb81dcb83bea89774` | `FuzzyMatch` |
| STTextView-Plugin-Neon | `5a30db4ce7908a5414e7b499e2379bdc49991cd1` | `STTextView-Plugin-Neon` |
| STTextView | 2.3.8（仓库内既有副本，无上游远程引用） | `STTextView` |
| Neon | `ce8d252c8fd53ea0b6960e02c423315eef11f141` | `Neon` |
| SwiftTreeSitter | 0.25.0 / `08ef81eb8620617b55b08868126707ad72bf754f` | `SwiftTreeSitter` |
| Tree-sitter | 0.25.10 / `da6fe9beb4f7f67beb75914ca8e0d48ae48d6406` | `tree-sitter` |
| Rearrange | 1.8.1 / `5ff7f3363f7a08f77e0d761e38e6add31c2136e1` | `Rearrange` |
| MSDisplayLink | 2.1.0 / `1ba3e769b734e456317fa7e45321fa7f53eefb67` | `MSDisplayLink` |
| STTextKitPlus | 0.3.0 / `2ee74906f4d753458eeaa9a2f6d4538aacb86a1d` | `STTextKitPlus` |
| CoreTextSwift | 0.2.0 / `833177201d6421e6322296f39fce6ff6ae52618a` | `CoreTextSwift` |

## 终端命令记录

Ghostty 的 macOS arm64、arm64e、x86_64 静态库由 `libghostty-spm/Ghostty.ref`
固定的上游源码和 `Patches/ghostty/` 内补丁重建。`0012-command-records.patch` 添加
有界 OSC 133 命令元数据、原生 tracked-pin 定位及 C 接口；其余平台仍使用 storage.1.3.7
的原始 slices。macOS 重建保留固定库中未修改的 Metal shader payload（SHA-256
`ef09de8917aaa15f0ebb4847555234b10f938c04d8e17457fe3c90d80a5a2e9d`）。
`Script/build-platform.sh <source> macos <output>` 可重建 macOS 库，产出库与头文件须一起
替换对应 slice。Ghostty 上游许可证与 Swift 包许可证保留在 `libghostty-spm/` 中。

Alacritty core 和 VTE 从固定 crates.io 版本复制，改为桥内的 path 依赖，remote 也复用同一
源码。改动说明见各自 `ZSHELL_PATCHES.md`；core 保留 Apache-2.0，VTE 保留 MIT 和
Apache-2.0。命令锚点随已有 grid reflow 移动，清除或覆盖输出后失效；没有新增第二套
VT 解析器或终端渲染器。

## swift-markdown / swift-cmark

swift-markdown 最初以 `XCRemoteSwiftPackageReference` 固定 revision 引入（Markdown 预览），
每次解析包图都会访问 github.com。现已把 pinned revision 的完整源码复制进
`swift-markdown/` 与 `swift-cmark/`（不含 .git），`swift-markdown/Package.swift` 的
swift-cmark 依赖改写为 `.package(path: "../swift-cmark")`，并移除了未使用的
swift-docc-plugin 远程依赖。工程内 `Markdown` 产品依赖指向 `Vendor/swift-markdown`
本地包引用，`Package.resolved` 因此删除（包图已无远程源）。

另外，SwiftPM 的 manifest 解析、Swift 宏展开（swift-plugin-server）与用户脚本阶段都会在
xcodebuild 之下嵌套 sandbox-exec。在已被 seatbelt 沙箱包裹的进程里（代理 shell、CI runner、
Homebrew 等），macOS 以 `sandbox_apply: Operation not permitted`（EPERM）拒绝嵌套，构建随之
以 "Could not resolve package dependencies" 失败。`mac/Makefile` 会自动探测这种情况，仅在
命中时为 xcodebuild 追加 `-IDEPackageSupportDisableManifestSandbox=1`、
`OTHER_SWIFT_FLAGS=-disable-sandbox` 与 `ENABLE_USER_SCRIPT_SANDBOXING=NO`（三者均为
xcodebuild 官方支持的设置）；正常终端探测通过，不追加任何参数。

升级方法：从上游 swiftlang/swift-markdown、swiftlang/swift-cmark 检出新 revision 覆盖这两个
目录（cmark 需与 markdown 要求的 gfm 分支一致），重新改写 manifest 中的 path 依赖，更新上表
revision 后提交。

## Sparkle 发布工具

`Sparkle/bin/` 内的 `generate_appcast`、`sign_update`、`generate_keys`、`BinaryDelta`
取自同一个 2.9.4 发布包。Sparkle 改为仓库内 binary target 后，Xcode 不再把 SPM
artifact 解包到 DerivedData，`scripts/generate-appcast.ts` 原有的 DerivedData 回退路径
因此失效；`Makefile` 默认导出 `SPARKLE_BIN` 指向这里，让发布脚本继续找到工具。
