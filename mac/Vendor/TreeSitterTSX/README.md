# TreeSitterTSX

**English** | [简体中文](README.zh-CN.md)

The tree-sitter **TSX** grammar — TypeScript *with* JSX — exposed as a local
SwiftPM package so zshell can link `tree_sitter_tsx()`.

## Why this is vendored

tree-sitter-typescript ships **two separate grammars**: `typescript` and `tsx`.
They aren't dialects of one parser — `typescript` has no JSX node types at all
(the TypeScript parser has no `jsx_opening_element`), because JSX's `<tag>` is
ambiguous with TypeScript's `<T>x` type
assertion and the grammar has to pick one. So parsing a `.tsx` file with the
`typescript` grammar turns every element into a parse error and the whole JSX
body of the file renders miscolored.

zshell's grammars otherwise come from `STTextView-Plugin-Neon`, which *does*
carry a `TreeSitterTSX` target — but it's unreachable: the package's only
product is `STTextView-Plugin-Neon`, `TreeSitterResource` doesn't depend on the
TSX target, and `TreeSitterLanguage` has no `.tsx` case. Nothing in the graph
references it, so SwiftPM never builds it and Xcode can't link a bare target
that isn't part of a product. Short of forking the plugin, vendoring the
grammar is the way to get the symbol.

Only the parser is vendored, not the queries: TSX's `highlights.scm` is
byte-identical to TypeScript's, which zshell already reaches through
`TreeSitterTypeScriptQueries`. The JSX captures come from JavaScript's
`highlights-jsx.scm`; `SyntaxHighlighting.highlightsData(for:)` merges the
three.

## Provenance

The generated parser and scanner come from
[tree-sitter-typescript](https://github.com/tree-sitter/tree-sitter-typescript)
tag `v0.23.2`, commit `f975a621f4e7f532fe322e13c4f79495e0a7b2e7`
(grammar ABI `LANGUAGE_VERSION 14`). The MIT license is retained beside the
sources. The shared upstream `common/scanner.h` is stored as `src/scanner.h`,
and the scanner's include uses that local path; the parser is unmodified.

The TypeScript and TSX targets in `STTextView-Plugin-Neon` use the same grammar
revision. Its TypeScript query resources are copied from that tag too, so the
app's merged TypeScript and JSX highlight queries match the grammar. The local
Swift package retains the `TreeSitterTSX` library product, `tree_sitter_tsx()`
symbol and existing public header.

To update, copy `tsx/src/` and `common/scanner.h` from a fixed upstream tag,
rewrite the scanner include, and refresh the plugin's TypeScript/TSX parsers
and query resources together. Verify query compilation, TSX parsing and the
app's highlighting on the vendored Tree-sitter runtime.
