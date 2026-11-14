# TreeSitterTSX

**简体中文** | [English](README.md)

将 tree-sitter 的 **TSX** 语法（支持 JSX 的 TypeScript）导出为本地 SwiftPM 包，
让 Zshell 能够链接 `tree_sitter_tsx()`。

## 为什么在仓库中保存这份源码

tree-sitter-typescript 提供 `typescript` 和 `tsx` **两套独立语法**。TypeScript
解析器没有 JSX 节点类型，也没有 `jsx_opening_element`：JSX 的 `<tag>` 与 TypeScript
的 `<T>x` 类型断言存在歧义，语法必须选择其中一种。因此，用 `typescript` 语法解析
`.tsx` 文件会将每个 JSX 元素识别为解析错误，导致整段 JSX 的高亮颜色出错。

Zshell 的其他语法来自 `STTextView-Plugin-Neon`。该包包含 `TreeSitterTSX` target，
但依赖图无法到达它：包的唯一 product 是 `STTextView-Plugin-Neon`，
`TreeSitterResource` 不依赖 TSX target，`TreeSitterLanguage` 也没有 `.tsx` case。
SwiftPM 因此不会构建它，Xcode 无法链接未包含在 product 中的独立 target。保存这份
语法源码并提供本地包，让应用能直接使用该符号。

这里只保存解析器，不保存查询规则：TSX 的 `highlights.scm` 与 TypeScript 的文件
逐字节相同，Zshell 已通过 `TreeSitterTypeScriptQueries` 读取它。JSX capture 来自
JavaScript 的 `highlights-jsx.scm`，`SyntaxHighlighting.highlightsData(for:)`
合并这三份规则。

## 来源

生成的解析器和扫描器来自
[tree-sitter-typescript](https://github.com/tree-sitter/tree-sitter-typescript)
的 `v0.23.2` tag，commit 为 `f975a621f4e7f532fe322e13c4f79495e0a7b2e7`，语法 ABI
为 `LANGUAGE_VERSION 14`。MIT 许可证保留在源码旁。上游共用的 `common/scanner.h`
保存为 `src/scanner.h`，扫描器的 include 改为该本地路径；解析器保持原样。

`STTextView-Plugin-Neon` 中的 TypeScript 和 TSX target 使用同一语法 revision，
TypeScript 查询资源也取自该 tag，让应用合并的 TypeScript 与 JSX 高亮规则和语法
匹配。本地 Swift 包保留 `TreeSitterTSX` library product、`tree_sitter_tsx()` 符号
及既有公共头文件。

更新时，从固定上游 tag 复制 `tsx/src/` 和 `common/scanner.h`，改写扫描器 include，
同时更新插件中的 TypeScript/TSX 解析器和查询资源。使用仓库内固定的 Tree-sitter
运行时验证查询编译、TSX 解析及应用高亮。
