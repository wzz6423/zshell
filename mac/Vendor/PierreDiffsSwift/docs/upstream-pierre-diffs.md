# Upstream @pierre/diffs Notes

PierreDiffsSwift wraps a pinned bundled build of `@pierre/diffs`.

## Current Pin

- npm package: `@pierre/diffs`
- pinned version: `1.3.1`
- configured in: `scripts/package.json`
- bundled output: `Sources/PierreDiffsSwift/Resources/pierre-diffs-bundle.js`
- build pins: `shiki@4.3.1` and `@shikijs/themes@4.3.1` (required so esbuild can resolve theme imports from `@pierre/theming`)

## Before Integrating Upstream APIs

1. Read the pinned dependency version in `scripts/package.json`.
2. Run `cd scripts && npm install` if `scripts/node_modules` is missing.
3. Check the local type declarations for the pinned version:
   - `scripts/node_modules/@pierre/diffs/dist/components/FileDiff.d.ts`
   - `scripts/node_modules/@pierre/diffs/dist/components/CodeView.d.ts`
   - `scripts/node_modules/@pierre/diffs/dist/types.d.ts`
4. Cross-check current upstream docs and releases:
   - https://diffs.com/docs
   - https://diffs.com/
   - https://github.com/pierrecomputer/pierre/releases
5. Prefer additive Swift wrapper APIs that preserve `PierreDiffView` defaults.
6. Rebuild the bundle with `cd scripts && npm run build`.
7. Run `swift test`.

Do not assume upstream `latest` docs match the pinned bundled version. If the npm pin changes, update this file, `CHANGELOG.md`, `README.md`, `AGENTS.md`, and `CLAUDE.md`.

## Wrapper Scope

`PierreDiffView` wraps upstream `FileDiff`. Low-risk `FileDiff` options can be exposed through `PierreDiffRenderOptions`.

`PierreMultiDiffView` wraps upstream `CodeView`, the virtualized multi-file review surface (since 1.4.0). Notes for changing it:

- Items are built in `diff-entry.js` with `parseDiffFromFile(oldFile, newFile)`; a `CodeViewDiffItem` needs `FileDiffMetadata`, not raw contents.
- `CodeView.setOptions` **replaces** the options object rather than merging, so the bridge keeps the last full set (`currentCodeViewOptions`) and patches it.
- `CodeView` keeps an existing record untouched when an updated item's `version` matches, so items carry a content fingerprint as their version.
- `itemMetrics.lineHeight` is the virtualizer's pre-measurement row estimate; it is derived from the applied font and must follow font changes.
- Only one surface is live at a time: `renderDiff` and `renderFiles` each tear the other down, since they share `#diff-container`.
- Edit mode is intentionally exposed only on `PierreMultiDiffView`: `PierreDiffFile.isEditable` maps to the CodeView item's `edit` flag. CodeView owns one `Editor` per active item, while `onFileEditChange` and `onFileEditComplete` return contents to the Swift consumer for persistence.
- Highlighting **must** stay on the worker pool. Virtualization tokenizes a file when it scrolls into view, so on the main thread that cost lands in a scroll frame (~750ms for an 85KB file in a WKWebView). `scripts/src/worker-entry.js` bundles `@pierre/diffs/worker/worker-portable.js` separately; `bundle.js` inlines it as a string and the bridge starts workers from a blob URL, because the page has a null origin. That worker build needs `ignoreAnnotations: true` — the package's `sideEffects` field otherwise tree-shakes the side-effect-only worker down to an empty file.
- `parseDiffFromFile` only produces a `cacheKey` when *both* `FileContents` carry one, and the worker cache is keyed on it, so keys must be derived from contents.
