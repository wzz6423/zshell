import AppKit
import WebKit

/// AppKit host for the same virtualized CodeView pipeline as PierreMultiDiffView.
@MainActor
public final class PierreMultiDiffNSView: NSView {
  private let coordinator: DiffWebViewCoordinator
  public let webView: WKWebView

  public var onFileEditChange: ((String, String) -> Void)? {
    didSet { coordinator.onFileEditChange = onFileEditChange }
  }
  public var onFileEditComplete: ((String, String) -> Void)? {
    didSet { coordinator.onFileEditComplete = onFileEditComplete }
  }
  public var onAnnotationClick: ((String) -> Void)? {
    didSet {
      coordinator.onAnnotationClick = { [weak self] id, _, _, _ in self?.onAnnotationClick?(id) }
    }
  }
  public var onReady: (() -> Void)? {
    didSet { coordinator.onReady = onReady }
  }

  public override init(frame frameRect: NSRect) {
    coordinator = DiffWebViewCoordinator()
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(coordinator, name: "diffBridge")
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init(frame: frameRect)
    webView.navigationDelegate = coordinator
    webView.allowsMagnification = true
    webView.setValue(false, forKey: "drawsBackground")
    coordinator.webView = webView
    webView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(webView)
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: trailingAnchor),
      webView.topAnchor.constraint(equalTo: topAnchor),
      webView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    webView.loadHTMLString(DiffHTMLTemplate.generateHTML(), baseURL: URL(string: "about:blank"))
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  isolated deinit { coordinator.cleanup() }

  public func update(
    files: [PierreDiffFile], diffStyle: DiffStyle, overflowMode: OverflowMode = .scroll,
    renderOptions: PierreDiffRenderOptions = PierreDiffRenderOptions(),
    scrollRequest: PierreDiffScrollRequest? = nil, usesDarkAppearance: Bool
  ) {
    let theme = usesDarkAppearance ? "dark" : "light"
    let previousOptions = coordinator.lastRenderOptions
    var normalizedPrevious = previousOptions
    normalizedPrevious?.font = renderOptions.font
    let fullRender = coordinator.lastFiles != files || normalizedPrevious != renderOptions
    if fullRender {
      coordinator.lastFiles = files
      coordinator.lastRenderOptions = renderOptions
      coordinator.lastDiffStyle = diffStyle
      coordinator.lastOverflowMode = overflowMode
      coordinator.lastTheme = theme
      coordinator.renderFiles(files, theme: theme, diffStyle: diffStyle,
                              overflowMode: overflowMode, renderOptions: renderOptions)
    } else {
      if coordinator.lastDiffStyle != diffStyle {
        coordinator.lastDiffStyle = diffStyle
        coordinator.setDiffStyle(diffStyle)
      }
      if coordinator.lastOverflowMode != overflowMode {
        coordinator.lastOverflowMode = overflowMode
        coordinator.setOverflow(overflowMode)
      }
      if coordinator.lastTheme != theme {
        coordinator.lastTheme = theme
        coordinator.setTheme(theme)
      }
      if previousOptions?.font != renderOptions.font {
        coordinator.lastRenderOptions = renderOptions
        coordinator.setFont(renderOptions.font)
      }
    }
    if let scrollRequest, coordinator.lastScrollRequest != scrollRequest {
      coordinator.lastScrollRequest = scrollRequest
      coordinator.scrollToFile(scrollRequest)
    }
  }

  public func cleanup() { coordinator.cleanup() }
}
