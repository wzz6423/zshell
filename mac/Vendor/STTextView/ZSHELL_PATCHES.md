# Why zshell vendors STTextView

This is upstream [STTextView](https://github.com/krzyzanowskim/STTextView)
tag `2.4.1`, commit `bbdcfd9d413ad3055dafd23a223be9bd39742f89`, with Zshell's
source patches. Xcode references it as a **root package**. Keep that registration:
it lets this fork override the `sttextview` identity used by the plugin graph.
All package dependencies remain local paths.

## Local patches

- `Sources/STTextViewAppKit/STTextView+Gutter.swift`: ignore detached fragment
  views after restyling so stale layout fragments cannot shift line numbering.
- `Sources/STTextViewAppKit/STTextView.swift`: retain a 16-point gap after the
  last glyph in horizontally resizable documents, and let short vertically
  resizable documents fill the viewport so clicks below the text reach the editor.
- `Sources/STTextViewCommon/STTextLayoutManager.swift`: skip rendering attributes
  over empty ranges. TextKit can raise `NSInvalidArgumentException` for zero-length
  highlight tokens on macOS 15/26.
- `Sources/STTextViewAppKit/STTextFinderBarContainer.swift` and
  `Sources/STTextViewAppKit/Gutter/STGutterView.swift`: keep the gutter registered
  as a floating subview when the find bar changes, and remove the find-bar height
  from its offset so line numbers continue scrolling beside the text.
- `Sources/STTextViewAppKit/STTextFinderClient.swift`: group Replace All into one
  undo operation, close typing coalescing before that group, and close the group
  on completion or the next main-actor turn.

Upstream `2.4.1` now uses the widest laid-out line and its trailing fragment
padding when sizing content. Those upstream changes replace the two earlier
width-estimation patches; the local trailing gap and viewport-fill behavior
remain. The horizontal-scrolling regression in `SizeToFitTests.swift` is retained,
and `ViewportLayoutTests.swift` includes the same trailing-gap expectation.

## Updating

1. Compare `Sources/` against the pinned upstream tree before replacing it;
   not every local patch carries a `zshell patch` marker.
2. Copy the new release sources, retain local path dependencies and root-package
   identity, then reapply the patches above unless upstream fixes the same cause.
3. Run the relevant Swift package regressions, build the app, and exercise editing,
   long lines, font changes, finding/replacing and gutter scrolling.

Editor scroll-view configuration belongs in `mac/zshell/SourceTextEditor.swift`;
keep those settings on the app side. Ordinary builds use only the checked-in
package sources and never fetch STTextView remotely.
