//
//  PierreDiffView.swift
//  PierreDiffsSwift
//
//  Created by James Rochabrun on 1/6/26.
//

import SwiftUI
import WebKit

/// A SwiftUI view that renders code diffs using the @pierre/diffs JavaScript library.
///
/// This view wraps a WKWebView that loads a bundled JavaScript library for rendering
/// rich, syntax-highlighted diffs with features like:
/// - Split and unified view modes
/// - Syntax highlighting via Shiki
/// - Inline word-level change highlighting
/// - Dark/light theme support
public struct PierreDiffView: NSViewRepresentable {

  // MARK: - Properties

  /// The original file content (before changes)
  let oldContent: String

  /// The updated file content (after changes)
  let newContent: String

  /// The name of the file being diffed (used for syntax highlighting detection)
  let fileName: String

  /// The current diff view style
  @Binding var diffStyle: DiffStyle

  /// The current overflow mode (scroll or wrap)
  @Binding var overflowMode: OverflowMode

  /// Additional renderer options passed through to @pierre/diffs
  var renderOptions: PierreDiffRenderOptions

  /// Callback when the user clicks on a line
  var onLineClick: ((Int, String) -> Void)?

  /// Callback when the user clicks on a line, with position data for UI overlay positioning
  var onLineClickWithPosition: ((LineClickPosition, CGPoint) -> Void)?

  /// Callback when a range of lines is selected via drag
  var onLineSelectionChange: ((LineSelectionRange) -> Void)?

  /// Callback when the view requests expansion to full screen
  var onExpandRequest: (() -> Void)?

  /// Inline annotations to display on the diff
  var annotations: [DiffAnnotation]?

  /// Callback when an annotation is clicked (id, side, lineNumber, localPoint)
  var onAnnotationClick: ((String, String, Int, CGPoint) -> Void)?

  /// Callback when an annotation delete is requested (id, side, lineNumber)
  var onAnnotationDelete: ((String, String, Int) -> Void)?

  /// Callback when the WebView is ready to display content
  var onReady: (() -> Void)?

  // MARK: - Environment

  @Environment(\.colorScheme) private var colorScheme

  // MARK: - Initialization

  public init(
    oldContent: String,
    newContent: String,
    fileName: String,
    diffStyle: Binding<DiffStyle>,
    overflowMode: Binding<OverflowMode>,
    renderOptions: PierreDiffRenderOptions = PierreDiffRenderOptions(),
    annotations: [DiffAnnotation]? = nil,
    onLineClick: ((Int, String) -> Void)? = nil,
    onLineClickWithPosition: ((LineClickPosition, CGPoint) -> Void)? = nil,
    onLineSelectionChange: ((LineSelectionRange) -> Void)? = nil,
    onAnnotationClick: ((String, String, Int, CGPoint) -> Void)? = nil,
    onAnnotationDelete: ((String, String, Int) -> Void)? = nil,
    onExpandRequest: (() -> Void)? = nil,
    onReady: (() -> Void)? = nil
  ) {
    self.oldContent = oldContent
    self.newContent = newContent
    self.fileName = fileName
    self._diffStyle = diffStyle
    self._overflowMode = overflowMode
    self.renderOptions = renderOptions
    self.annotations = annotations
    self.onLineClick = onLineClick
    self.onLineClickWithPosition = onLineClickWithPosition
    self.onLineSelectionChange = onLineSelectionChange
    self.onAnnotationClick = onAnnotationClick
    self.onAnnotationDelete = onAnnotationDelete
    self.onExpandRequest = onExpandRequest
    self.onReady = onReady
  }

  // MARK: - NSViewRepresentable

  public func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()

    // Set up message handler for JavaScript to Swift communication
    configuration.userContentController.add(
      context.coordinator,
      name: "diffBridge"
    )

    // Configure preferences
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsMagnification = true

    // Make background transparent to blend with SwiftUI
    webView.setValue(false, forKey: "drawsBackground")

    // Store reference in coordinator
    context.coordinator.webView = webView

    // Load the initial HTML
    loadHTML(into: webView)

    return webView
  }

  public func updateNSView(_ webView: WKWebView, context: Context) {
    let coordinator = context.coordinator

    // Check if content has changed
    let contentChanged = coordinator.lastOldContent != oldContent ||
                         coordinator.lastNewContent != newContent ||
                         coordinator.lastFileName != fileName

    // Check if style has changed
    let styleChanged = coordinator.lastDiffStyle != diffStyle

    // Check if overflow mode has changed
    let overflowChanged = coordinator.lastOverflowMode != overflowMode

    // Check if theme has changed
    let currentTheme = themeForColorScheme
    let themeChanged = coordinator.lastTheme != currentTheme

    // Check if render options have changed (font can update without a full re-render)
    let previousRenderOptions = coordinator.lastRenderOptions
    let renderOptionsChanged = previousRenderOptions != renderOptions
    let nonFontRenderOptionsChanged: Bool = {
      guard let previousRenderOptions else { return renderOptionsChanged }
      var normalizedPrevious = previousRenderOptions
      normalizedPrevious.font = renderOptions.font
      return normalizedPrevious != renderOptions
    }()
    let fontOnlyChanged = renderOptionsChanged && !nonFontRenderOptionsChanged

    // Check if annotations have changed
    let annotationsChanged = coordinator.lastAnnotations != annotations
    let requiresFullRender = contentChanged || nonFontRenderOptionsChanged

    if requiresFullRender {
      coordinator.lastOldContent = oldContent
      coordinator.lastNewContent = newContent
      coordinator.lastFileName = fileName
      coordinator.lastDiffStyle = diffStyle
      coordinator.lastOverflowMode = overflowMode
      coordinator.lastTheme = currentTheme
      coordinator.lastRenderOptions = renderOptions
      coordinator.lastAnnotations = annotations
      coordinator.renderDiff(
        oldContent: oldContent,
        newContent: newContent,
        fileName: fileName,
        theme: currentTheme,
        diffStyle: diffStyle,
        overflowMode: overflowMode,
        renderOptions: renderOptions,
        annotations: annotations
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

    if !requiresFullRender && annotationsChanged {
      coordinator.lastAnnotations = annotations
      if let annotations, !annotations.isEmpty {
        coordinator.setAnnotations(annotations)
      } else {
        coordinator.removeAnnotations()
      }
    }
  }

  public func makeCoordinator() -> DiffWebViewCoordinator {
    DiffWebViewCoordinator(
      onLineClick: onLineClick,
      onLineClickWithPosition: onLineClickWithPosition,
      onLineSelectionChange: onLineSelectionChange,
      onExpandRequest: onExpandRequest,
      onReady: onReady,
      onAnnotationClick: onAnnotationClick,
      onAnnotationDelete: onAnnotationDelete
    )
  }

  public static func dismantleNSView(_ nsView: WKWebView, coordinator: DiffWebViewCoordinator) {
    coordinator.cleanup()
  }

  // MARK: - Private Helpers

  private var themeForColorScheme: String {
    colorScheme == .dark ? "dark" : "light"
  }

  private func loadHTML(into webView: WKWebView) {
    let html = DiffHTMLTemplate.generateHTML()
    webView.loadHTMLString(html, baseURL: nil)
  }
}
