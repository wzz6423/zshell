//
//  PierreMultiDiffView.swift
//  PierreDiffsSwift
//

import SwiftUI
import WebKit

/// A SwiftUI view that renders many file diffs stacked in one scroll surface —
/// the whole change set of a commit, branch, or working tree at once.
///
/// Unlike `PierreDiffView`, which renders a single `FileDiff`, this wraps
/// `@pierre/diffs`' `CodeView`: rows are virtualized, so only what is on screen
/// is rendered and a large change set stays responsive. Use `scrollRequest` to
/// jump to a particular file — for example from a file list beside the diff.
public struct PierreMultiDiffView: NSViewRepresentable {

  // MARK: - Properties

  /// The files to render, in display order.
  let files: [PierreDiffFile]

  /// The current diff view style
  @Binding var diffStyle: DiffStyle

  /// The current overflow mode (scroll or wrap)
  @Binding var overflowMode: OverflowMode

  /// Additional renderer options passed through to the underlying views
  var renderOptions: PierreDiffRenderOptions

  /// File to scroll to. Bump the request's `token` to scroll to the same file
  /// again; requests naming a file that has not rendered yet are applied once
  /// it does.
  var scrollRequest: PierreDiffScrollRequest?

  /// Callback when the user clicks on a line (lineNumber, side)
  var onLineClick: ((Int, String) -> Void)?

  /// Callback when a range of lines is selected via drag
  var onLineSelectionChange: ((LineSelectionRange) -> Void)?

  /// Callback on every edit (file ID, updated contents).
  var onFileEditChange: ((String, String) -> Void)?

  /// Callback when an edited item leaves edit mode (file ID, final contents).
  var onFileEditComplete: ((String, String) -> Void)?

  /// Callback when the WebView is ready to display content
  var onReady: (() -> Void)?

  // MARK: - Environment

  @Environment(\.colorScheme) private var colorScheme

  // MARK: - Initialization

  public init(
    files: [PierreDiffFile],
    diffStyle: Binding<DiffStyle>,
    overflowMode: Binding<OverflowMode>,
    renderOptions: PierreDiffRenderOptions = PierreDiffRenderOptions(),
    scrollRequest: PierreDiffScrollRequest? = nil,
    onLineClick: ((Int, String) -> Void)? = nil,
    onLineSelectionChange: ((LineSelectionRange) -> Void)? = nil,
    onFileEditChange: ((String, String) -> Void)? = nil,
    onFileEditComplete: ((String, String) -> Void)? = nil,
    onReady: (() -> Void)? = nil
  ) {
    self.files = files
    self._diffStyle = diffStyle
    self._overflowMode = overflowMode
    self.renderOptions = renderOptions
    self.scrollRequest = scrollRequest
    self.onLineClick = onLineClick
    self.onLineSelectionChange = onLineSelectionChange
    self.onFileEditChange = onFileEditChange
    self.onFileEditComplete = onFileEditComplete
    self.onReady = onReady
  }

  // MARK: - NSViewRepresentable

  public func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(context.coordinator, name: "diffBridge")
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsMagnification = true
    webView.setValue(false, forKey: "drawsBackground")

    context.coordinator.webView = webView
    webView.loadHTMLString(DiffHTMLTemplate.generateHTML(), baseURL: nil)

    return webView
  }

  public func updateNSView(_ webView: WKWebView, context: Context) {
    let coordinator = context.coordinator
    let currentTheme = colorScheme == .dark ? "dark" : "light"

    let filesChanged = coordinator.lastFiles != files
    let styleChanged = coordinator.lastDiffStyle != diffStyle
    let overflowChanged = coordinator.lastOverflowMode != overflowMode
    let themeChanged = coordinator.lastTheme != currentTheme

    let previousRenderOptions = coordinator.lastRenderOptions
    let renderOptionsChanged = previousRenderOptions != renderOptions
    let nonFontRenderOptionsChanged: Bool = {
      guard let previousRenderOptions else { return renderOptionsChanged }
      var normalizedPrevious = previousRenderOptions
      normalizedPrevious.font = renderOptions.font
      return normalizedPrevious != renderOptions
    }()
    let fontOnlyChanged = renderOptionsChanged && !nonFontRenderOptionsChanged
    let requiresFullRender = filesChanged || nonFontRenderOptionsChanged

    if requiresFullRender {
      coordinator.lastFiles = files
      coordinator.lastDiffStyle = diffStyle
      coordinator.lastOverflowMode = overflowMode
      coordinator.lastTheme = currentTheme
      coordinator.lastRenderOptions = renderOptions
      coordinator.renderFiles(
        files,
        theme: currentTheme,
        diffStyle: diffStyle,
        overflowMode: overflowMode,
        renderOptions: renderOptions
      )
    } else if styleChanged {
      coordinator.lastDiffStyle = diffStyle
      coordinator.setDiffStyle(diffStyle)
    } else if overflowChanged {
      coordinator.lastOverflowMode = overflowMode
      coordinator.setOverflow(overflowMode)
    } else if themeChanged {
      coordinator.lastTheme = currentTheme
      coordinator.setTheme(currentTheme)
    }

    if !requiresFullRender && fontOnlyChanged {
      coordinator.lastRenderOptions = renderOptions
      coordinator.setFont(renderOptions.font)
    }

    // Ordered after the render so a request arriving with new files lands on
    // the freshly rendered list rather than the one it replaced.
    if let scrollRequest, coordinator.lastScrollRequest != scrollRequest {
      coordinator.lastScrollRequest = scrollRequest
      coordinator.scrollToFile(scrollRequest)
    }
  }

  public func makeCoordinator() -> DiffWebViewCoordinator {
    DiffWebViewCoordinator(
      onLineClick: onLineClick,
      onLineSelectionChange: onLineSelectionChange,
      onFileEditChange: onFileEditChange,
      onFileEditComplete: onFileEditComplete,
      onReady: onReady
    )
  }

  public static func dismantleNSView(_ nsView: WKWebView, coordinator: DiffWebViewCoordinator) {
    coordinator.cleanup()
  }
}
