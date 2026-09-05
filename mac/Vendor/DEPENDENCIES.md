# 固定第三方依赖

macOS 应用使用本目录内的第三方源码和 XCFramework。普通构建不会从远程仓库解析或下载依赖；升级依赖时，单独更新对应目录、核对版本和许可证后再提交。

| 依赖 | 固定版本 / revision | 本地目录 |
| --- | --- | --- |
| GhosttyKit | storage.1.3.7 | `libghostty-spm/GhosttyKit.xcframework` |
| Sparkle | 2.9.4 | `Sparkle/Sparkle.xcframework` |
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

## Sparkle 发布工具

`Sparkle/bin/` 内的 `generate_appcast`、`sign_update`、`generate_keys`、`BinaryDelta`
取自同一个 2.9.4 发布包。Sparkle 改为仓库内 binary target 后，Xcode 不再把 SPM
artifact 解包到 DerivedData，`scripts/generate-appcast.ts` 原有的 DerivedData 回退路径
因此失效；`Makefile` 默认导出 `SPARKLE_BIN` 指向这里，让发布脚本继续找到工具。
