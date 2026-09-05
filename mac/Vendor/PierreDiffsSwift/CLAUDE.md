# PierreDiffsSwift

## What This Project Is

A Swift package that wraps the `@pierre/diffs` JavaScript library (v1.3.1) to render syntax-highlighted code diffs in macOS apps via WKWebView. It provides SwiftUI views, line interaction callbacks, editable multi-file diffs, and an inline annotation system.

## Architecture

```
PierreDiffView (SwiftUI NSViewRepresentable) — one file
PierreMultiDiffView (SwiftUI NSViewRepresentable) — a whole change set, virtualized
  ├── WKWebView
  │     ├── DiffHTMLTemplate (HTML + CSS)
  │     └── pierre-diffs-bundle.js (esbuild bundle of @pierre/diffs + diff-entry.js)
  ├── DiffWebViewCoordinator (WKNavigationDelegate + WKScriptMessageHandler)
  │     ├── JS → Swift messaging via webkit.messageHandlers.diffBridge
  │     └── Swift → JS via evaluateJavaScript / base64-encoded callJavaScript
  └── Change detection in updateNSView (content, style, overflow, render options, theme, annotations)
```

### Key Files

| File | Purpose |
|------|---------|
| `Sources/.../WebView/PierreDiffView.swift` | Single-file NSViewRepresentable — wraps upstream `FileDiff` |
| `Sources/.../WebView/PierreMultiDiffView.swift` | Multi-file NSViewRepresentable — wraps upstream `CodeView` |
| `Sources/.../WebView/DiffWebViewCoordinator.swift` | WKWebView delegate, JS bridge, event handling |
| `Sources/.../WebView/DiffHTMLTemplate.swift` | HTML generation with embedded CSS and JS bundle |
| `Sources/.../WebView/DiffWebViewEvent.swift` | Enum of all events from JS → Swift |
| `Sources/.../Models/DiffAnnotation.swift` | `DiffAnnotation`, `AnnotationMetadata`, `AnnotationSide` |
| `Sources/.../Models/PierreDiffInput.swift` | Codable input sent to JS `renderDiff()` |
| `Sources/.../Models/PierreMultiDiffInput.swift` | `PierreDiffFile`, `PierreDiffScrollRequest`, input sent to JS `renderFiles()` / `scrollToFile()` |
| `Sources/.../Types/PierreDiffRenderOptions.swift` | Public renderer option types passed through to `FileDiff` |
| `Sources/.../Models/LineClickPosition.swift` | Position data for line click callbacks |
| `Sources/.../Models/LineSelectionRange.swift` | Range data for multi-line selection callbacks |
| `scripts/src/diff-entry.js` | JS entry point — bridge API, annotation DOM, events |
| `scripts/bundle.js` | esbuild config |
| `scripts/package.json` | npm deps (`@pierre/diffs` pinned to 1.3.1) |
| `CHANGELOG.md` | Wrapper release notes |
| `docs/upstream-pierre-diffs.md` | Upstream docs/version checklist for agents |

### Data Flow

**Rendering**: Swift → `PierreDiffInput` (Codable) → base64 encode → JS `window.pierreBridge.renderDiff(input)` → `@pierre/diffs` FileDiff renders DOM

**Multi-file rendering**: Swift → `PierreMultiDiffInput` → base64 encode → JS `window.pierreBridge.renderFiles(input)` → `parseDiffFromFile` per file → `CodeView.setItems(...)`. `scrollToFile({id})` scrolls to one item, queuing the request until that file exists. Both surfaces share `#diff-container`, so only one is live at a time.

**Multi-file editing**: `PierreDiffFile.isEditable` → CodeView item `edit` → one upstream `Editor` per editable item. `onItemEditChange` / `onItemEditComplete` cross the JS bridge as `onFileEditChange` / `onFileEditComplete`. Consumers own persistence; the wrapper never writes files.

**Events**: JS `postToSwift(type, payload)` → `webkit.messageHandlers.diffBridge.postMessage(...)` → `WKScriptMessageHandler` → `DiffWebViewEvent` enum → `handleMessage()` → callbacks

**Annotations**: Swift passes `[DiffAnnotation]` → encoded to JSON → JS `setLineAnnotations()` → `@pierre/diffs` calls `renderAnnotation(annotation)` → `createAnnotationDOM()` builds HTML element

### Change Detection

`updateNSView` tracks previous values via coordinator properties (`lastOldContent`, `lastDiffStyle`, `lastRenderOptions`, `lastAnnotations`, etc.) and only calls the relevant JS method when a specific property changes. Content and render option changes trigger full re-render; style/theme/overflow/annotation changes use targeted update methods.

## Upstream Docs

Before exposing more `@pierre/diffs` APIs, read `docs/upstream-pierre-diffs.md`, then verify the pinned package's local declarations under `scripts/node_modules/@pierre/diffs/dist/`. Cross-check upstream docs and releases, but keep wrapper behavior aligned to the pinned version in `scripts/package.json`.

Current low-risk pass-through options live in `PierreDiffRenderOptions`: theme pair, font (`PierreDiffFont` CSS variables + optional bundled `PierreDiffFontFace` `@font-face` data URLs), diff indicators, hunk separator style, line diff type, line/header/background visibility, unchanged-hunk expansion, large-line diff limits, tokenization limits, and sticky headers. Keep defaults backward-compatible.

## Build Commands

```bash
# Rebuild JS bundle after editing scripts/src/diff-entry.js
cd scripts && npm install && npm run build

# Build Swift package
swift build

# Run tests
swift test
```

## Conventions

- Swift 6.0 strict concurrency — coordinator is `@MainActor`
- All public types are `Sendable`
- JS communication uses base64-encoded JSON to handle special characters safely
- CSS is theme-aware via `@media (prefers-color-scheme: dark)`
- Position callbacks use `NSEvent.mouseLocation` converted to WebView-local coordinates (top-left origin, matches SwiftUI)

## Annotation System

Annotations are **stateless from the library's perspective**. `PierreDiffView` renders whatever `[DiffAnnotation]` array it receives and fires callbacks on interaction. The consumer owns the state.

### Events from annotations:
- `onAnnotationClick(id, side, lineNumber, localPoint)` — user clicked annotation body
- `onAnnotationDelete(id, side, lineNumber)` — user clicked the X delete button

### Dynamic updates:
- Changing the `annotations` array triggers `updateNSView` → `coordinator.setAnnotations()` (no full re-render)
- Setting annotations to `nil` or `[]` calls `coordinator.removeAnnotations()`
