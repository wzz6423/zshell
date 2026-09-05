# Changelog

All notable changes to PierreDiffsSwift are documented here.

## 1.5.0 - 2026-08-04

### Added

- Added opt-in editing to diff items in `PierreMultiDiffView`. Set `PierreDiffFile.isEditable` and persist updates from `onFileEditChange`; `onFileEditComplete` reports the final contents when edit mode ends.

### Changed

- Bumped the bundled `@pierre/diffs` dependency from `1.2.12` to `1.3.1` and rebuilt the JavaScript bundle with its lazy edit layer.

## 1.4.1 - 2026-07-25

### Fixed

- Fixed stalls while scrolling `PierreMultiDiffView`. Because the surface is virtualized, a file is highlighted as it scrolls into view — and Shiki tokenization ran on the main thread, so reaching an unread file froze scrolling for as long as tokenizing it took (up to ~750ms per file in a WKWebView, for an 85KB source file). Highlighting now runs in a pool of Web Workers, and the files below the viewport are primed in the background, so rows mount against a cached AST. Measured on a nine-file change set: worst scroll frame went from 756ms to 34ms.

### Changed

- The bundle now carries a second, separately built worker bundle inlined as a string. Workers are started from a blob URL because `loadHTMLString(baseURL: nil)` leaves the page with a null origin and no URL to load a worker script from. When `Worker` is unavailable, highlighting falls back to the main thread as before.
- The multi-file bridge sets a content-derived `cacheKey` on each parsed diff, which is what the worker pool caches highlighting under.

## 1.4.0 - 2026-07-25

### Added

- Added `PierreMultiDiffView`, a SwiftUI view that renders a whole change set — every changed file stacked in one scroll surface. It wraps upstream `CodeView`, so items are virtualized and a large change set stays responsive.
- Added `PierreDiffFile` describing one file in that surface (`id`, `name`, optional `oldName` for renames, both sides' contents, optional `lang`). `PierreDiffFile.note(id:name:_:)` renders a file that cannot be diffed — binary, too large, unreadable — as a single explanatory line so it still appears in the list.
- Added `PierreDiffScrollRequest` for scrolling the surface to a file, with `alignment`, `animated`, and a `token` that re-triggers an otherwise identical request. Requests naming a file that has not rendered yet are applied once it does.
- Added `renderFiles` and `scrollToFile` to the JavaScript bridge, plus `CodeView` to the bundle.

### Changed

- `setTheme`, `setDiffStyle`, `setOverflow`, and `setFont` now drive whichever surface is live (single-file or multi-file); `setFont` also keeps the virtualizer's row-height estimate in sync.
- Rebuilt `Sources/PierreDiffsSwift/Resources/pierre-diffs-bundle.js` (now includes `CodeView`).

## 1.3.1 - 2026-07-24

### Fixed

- Fixed non-ASCII content (CJK, emoji, accented characters) rendering as mojibake — e.g. `内容` shown as `å†…å®¹` (egoist/kero#16). The injected bridge script decoded base64 with `atob()` alone, which produces a Latin-1 binary string, so multi-byte UTF-8 sequences were split into separate characters before `JSON.parse`. The bytes are now re-decoded with `TextDecoder('utf-8')` first. All bridge calls (`renderDiff`, `setFont`, `setAnnotations`) route through this path, so one fix covers them all.

## 1.3.0 - 2026-07-18

### Added

- Added `PierreDiffFont` for customizing code and header fonts via CSS variables:
  - `family` / `headerFamily`
  - `size` / `lineHeight` (CSS strings, or points via convenience initializer)
  - `tabSize`
  - `faces` for bundled `@font-face` injection (`.ttf` / `.otf` / `.woff` / `.woff2`)
- Added `PierreDiffFontFace` and `PierreDiffFontFormat` to load fonts from `Data`, file URLs, or bundle resources and embed them as data URLs in the WebView.
- Added `PierreDiffFont.bundled(familyName:faces:...)` helper that builds a CSS stack with system monospace fallbacks.
- Exposed font configuration on `PierreDiffRenderOptions.font` (defaults preserve historical 12px mono styling).
- Font-only option changes update CSS variables / `@font-face` rules without a full `FileDiff` re-render.

### Changed

- Bumped the bundled `@pierre/diffs` dependency from `1.2.7` to `1.2.12`.
- Pinned `shiki` / `@shikijs/themes` to `4.3.1` for the esbuild bundle (required by `@pierre/theming` theme imports in 1.2.12).
- Rebuilt `Sources/PierreDiffsSwift/Resources/pierre-diffs-bundle.js`.
- Updated package installation URL to `https://github.com/egoist-labs/PierreDiffsSwift`.

## 1.2.0 - 2026-06-04

### Added

- Added `PierreDiffRenderOptions` for low-risk @pierre/diffs render controls:
  - `theme`
  - `diffIndicators`
  - `hunkSeparators`
  - `lineDiffType`
  - `disableLineNumbers`
  - `disableFileHeader`
  - `disableBackground`
  - `expandUnchanged`
  - `collapsedContextThreshold`
  - `maxLineDiffLength`
  - `expansionLineCount`
  - `tokenizeMaxLength`
  - `tokenizeMaxLineLength`
  - `stickyHeader`
- Added public option enums: `DiffIndicatorStyle`, `LineDiffType`, and `HunkSeparatorStyle`.
- Added `PierreDiffTheme.pierre` and `PierreDiffTheme.pierreSoft`.
- Added upstream integration notes for agents in `docs/upstream-pierre-diffs.md`.

### Changed

- Bumped the bundled `@pierre/diffs` dependency from `1.1.12` to `1.2.7`.
- Rebuilt `Sources/PierreDiffsSwift/Resources/pierre-diffs-bundle.js`.
- Updated README and agent guidance for the new render options.

### Fixed

- Preserved the WebView scroll position when inline annotations are added, edited, or removed.
