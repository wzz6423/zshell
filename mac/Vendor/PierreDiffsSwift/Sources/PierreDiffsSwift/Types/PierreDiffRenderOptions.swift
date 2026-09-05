//
//  PierreDiffRenderOptions.swift
//  PierreDiffsSwift
//
//  Created by James Rochabrun on 6/4/26.
//

import Foundation

/// Built-in @pierre/diffs theme pair names.
public struct PierreDiffTheme: Codable, Sendable, Equatable {
  /// Theme name used when SwiftUI is in dark mode.
  public let dark: String

  /// Theme name used when SwiftUI is in light mode.
  public let light: String

  public init(dark: String, light: String) {
    self.dark = dark
    self.light = light
  }

  /// The default Pierre theme pair.
  public static let pierre = PierreDiffTheme(
    dark: "pierre-dark",
    light: "pierre-light"
  )

  /// Softer Pierre theme pair introduced by @pierre/diffs 1.2.
  public static let pierreSoft = PierreDiffTheme(
    dark: "pierre-dark-soft",
    light: "pierre-light-soft"
  )
}

/// How changed lines are marked in the diff gutter/body.
public enum DiffIndicatorStyle: String, CaseIterable, Identifiable, Codable, Sendable {
  case classic
  case bars
  case none

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .classic:
      return "Classic"
    case .bars:
      return "Bars"
    case .none:
      return "None"
    }
  }
}

/// How inline changes are highlighted inside changed lines.
public enum LineDiffType: String, CaseIterable, Identifiable, Codable, Sendable {
  case wordAlt = "word-alt"
  case word
  case char
  case none

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .wordAlt:
      return "Word Alt"
    case .word:
      return "Word"
    case .char:
      return "Character"
    case .none:
      return "None"
    }
  }
}

/// Built-in hunk separator styles supported by @pierre/diffs.
public enum HunkSeparatorStyle: String, CaseIterable, Identifiable, Codable, Sendable {
  case simple
  case metadata
  case lineInfo = "line-info"
  case lineInfoBasic = "line-info-basic"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .simple:
      return "Simple"
    case .metadata:
      return "Metadata"
    case .lineInfo:
      return "Line Info"
    case .lineInfoBasic:
      return "Line Info Basic"
    }
  }
}

/// CSS `@font-face` format for bundled/custom fonts injected into the WebView.
public enum PierreDiffFontFormat: String, CaseIterable, Identifiable, Codable, Sendable {
  case truetype
  case opentype
  case woff
  case woff2

  public var id: String { rawValue }

  /// MIME type used in the data URL for this format.
  public var mimeType: String {
    switch self {
    case .truetype:
      return "font/ttf"
    case .opentype:
      return "font/otf"
    case .woff:
      return "font/woff"
    case .woff2:
      return "font/woff2"
    }
  }

  /// Infers a format from a file path extension (e.g. `"ttf"`, `"otf"`, `"woff2"`).
  public static func infer(fromPathExtension pathExtension: String) -> PierreDiffFontFormat? {
    switch pathExtension.lowercased() {
    case "ttf":
      return .truetype
    case "otf":
      return .opentype
    case "woff":
      return .woff
    case "woff2":
      return .woff2
    default:
      return nil
    }
  }

  /// Infers a format from a file URL's path extension.
  public static func infer(from url: URL) -> PierreDiffFontFormat? {
    infer(fromPathExtension: url.pathExtension)
  }
}

/// A single `@font-face` source embedded as base64 and injected into the WebView.
///
/// Use this for fonts bundled with your app (`.ttf`, `.otf`, `.woff`, `.woff2`).
/// The CSS `family` must match the name used in `PierreDiffFont.family` /
/// `headerFamily`.
///
/// ```swift
/// let face = try PierreDiffFontFace(
///   family: "JetBrains Mono",
///   resource: "JetBrainsMono-Regular",
///   extension: "ttf"
/// )
/// let font = PierreDiffFont(
///   family: "'JetBrains Mono', ui-monospace, monospace",
///   sizePoints: 13,
///   faces: [face]
/// )
/// ```
public struct PierreDiffFontFace: Codable, Sendable, Equatable {
  /// CSS `font-family` name declared by this face (without quotes).
  public var family: String

  /// Base64-encoded font file bytes.
  public var data: String

  /// CSS `format(...)` / data-URL MIME mapping.
  public var format: PierreDiffFontFormat

  /// CSS `font-weight` (e.g. `"normal"`, `"400"`, `"700"`).
  public var weight: String

  /// CSS `font-style` (e.g. `"normal"`, `"italic"`).
  public var style: String

  public init(
    family: String,
    data: Data,
    format: PierreDiffFontFormat,
    weight: String = "normal",
    style: String = "normal"
  ) {
    self.family = family
    self.data = data.base64EncodedString()
    self.format = format
    self.weight = weight
    self.style = style
  }

  public init(
    family: String,
    base64Data: String,
    format: PierreDiffFontFormat,
    weight: String = "normal",
    style: String = "normal"
  ) {
    self.family = family
    self.data = base64Data
    self.format = format
    self.weight = weight
    self.style = style
  }

  /// Loads a font face from a file URL.
  public init(
    family: String,
    fileURL: URL,
    format: PierreDiffFontFormat? = nil,
    weight: String = "normal",
    style: String = "normal"
  ) throws {
    let resolvedFormat = try format ?? PierreDiffFontFormat.infer(from: fileURL).orThrow(
      PierreDiffFontFaceError.unsupportedFormat(fileURL.pathExtension)
    )
    let fontData = try Data(contentsOf: fileURL)
    self.init(
      family: family,
      data: fontData,
      format: resolvedFormat,
      weight: weight,
      style: style
    )
  }

  /// Loads a font face from a bundle resource.
  public init(
    family: String,
    resource name: String,
    extension ext: String,
    subdirectory: String? = nil,
    bundle: Bundle = .main,
    weight: String = "normal",
    style: String = "normal"
  ) throws {
    guard let url = bundle.url(
      forResource: name,
      withExtension: ext,
      subdirectory: subdirectory
    ) else {
      throw PierreDiffFontFaceError.resourceNotFound(
        name: name,
        extension: ext,
        bundleIdentifier: bundle.bundleIdentifier ?? bundle.bundlePath
      )
    }
    try self.init(
      family: family,
      fileURL: url,
      format: PierreDiffFontFormat.infer(fromPathExtension: ext),
      weight: weight,
      style: style
    )
  }

  /// Failable convenience for SwiftUI state setup.
  public static func load(
    family: String,
    resource name: String,
    extension ext: String,
    subdirectory: String? = nil,
    bundle: Bundle = .main,
    weight: String = "normal",
    style: String = "normal"
  ) -> PierreDiffFontFace? {
    try? PierreDiffFontFace(
      family: family,
      resource: name,
      extension: ext,
      subdirectory: subdirectory,
      bundle: bundle,
      weight: weight,
      style: style
    )
  }

  /// Failable convenience that loads from a file URL.
  public static func load(
    family: String,
    fileURL: URL,
    format: PierreDiffFontFormat? = nil,
    weight: String = "normal",
    style: String = "normal"
  ) -> PierreDiffFontFace? {
    try? PierreDiffFontFace(
      family: family,
      fileURL: fileURL,
      format: format,
      weight: weight,
      style: style
    )
  }
}

/// Errors when loading bundled font faces.
public enum PierreDiffFontFaceError: Error, LocalizedError, Sendable, Equatable {
  case resourceNotFound(name: String, extension: String, bundleIdentifier: String)
  case unsupportedFormat(String)

  public var errorDescription: String? {
    switch self {
    case .resourceNotFound(let name, let ext, let bundleIdentifier):
      return "Font resource \(name).\(ext) not found in bundle \(bundleIdentifier)"
    case .unsupportedFormat(let ext):
      return "Unsupported font format: \(ext.isEmpty ? "(none)" : ext). Use ttf, otf, woff, or woff2."
    }
  }
}

private extension Optional {
  func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
    guard let value = self else { throw error() }
    return value
  }
}

/// Font configuration for the diff view.
///
/// Values are applied as CSS custom properties that `@pierre/diffs` reads
/// (`--diffs-font-family`, `--diffs-font-size`, etc.). Use CSS units for size
/// and line height (for example `"13px"`, `"1.5"`, `"20px"`).
///
/// For **bundled fonts**, pass `faces` so the WebView can inject `@font-face`
/// rules with data URLs (system fonts only need `family`).
public struct PierreDiffFont: Codable, Sendable, Equatable {
  /// Default monospace stack used for code content.
  public static let defaultCodeFamily =
    "ui-monospace, 'SF Mono', Menlo, Monaco, 'Cascadia Code', 'Roboto Mono', monospace"

  /// Default sans-serif stack used for headers and hunk separators.
  public static let defaultHeaderFamily =
    "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif"

  /// CSS `font-family` for code content.
  public var family: String

  /// CSS `font-size` for code content (e.g. `"12px"`, `"0.875rem"`).
  public var size: String

  /// CSS `line-height` for code content (e.g. `"1.5"`, `"20px"`).
  public var lineHeight: String

  /// CSS `font-family` for headers and hunk separators.
  public var headerFamily: String

  /// Tab stop width in spaces (`tab-size`).
  public var tabSize: Int

  /// Bundled `@font-face` sources embedded into the WebView.
  ///
  /// Empty by default (system fonts only). Family names in each face must
  /// match names used in `family` / `headerFamily`.
  public var faces: [PierreDiffFontFace]

  /// Historical PierreDiffsSwift defaults (12px mono, unitless 1.5 line height).
  public static let `default` = PierreDiffFont()

  public init(
    family: String = PierreDiffFont.defaultCodeFamily,
    size: String = "12px",
    lineHeight: String = "1.5",
    headerFamily: String = PierreDiffFont.defaultHeaderFamily,
    tabSize: Int = 2,
    faces: [PierreDiffFontFace] = []
  ) {
    self.family = family
    self.size = size
    self.lineHeight = lineHeight
    self.headerFamily = headerFamily
    self.tabSize = max(1, tabSize)
    self.faces = faces
  }

  /// Convenience initializer using point sizes converted to CSS `px`.
  public init(
    family: String = PierreDiffFont.defaultCodeFamily,
    sizePoints: Double,
    lineHeight: Double = 1.5,
    headerFamily: String = PierreDiffFont.defaultHeaderFamily,
    tabSize: Int = 2,
    faces: [PierreDiffFontFace] = []
  ) {
    self.init(
      family: family,
      size: Self.cssPixels(sizePoints),
      lineHeight: Self.cssNumber(lineHeight),
      headerFamily: headerFamily,
      tabSize: tabSize,
      faces: faces
    )
  }

  /// Builds a font config for a single bundled face, with a system monospace fallback stack.
  public static func bundled(
    familyName: String,
    faces: [PierreDiffFontFace],
    sizePoints: Double = 12,
    lineHeight: Double = 1.5,
    headerFamily: String = PierreDiffFont.defaultHeaderFamily,
    tabSize: Int = 2
  ) -> PierreDiffFont {
    let quoted = familyName.contains(" ") || familyName.contains(",")
      ? "'\(familyName.replacingOccurrences(of: "'", with: "\\'"))'"
      : familyName
    return PierreDiffFont(
      family: "\(quoted), \(defaultCodeFamily)",
      sizePoints: sizePoints,
      lineHeight: lineHeight,
      headerFamily: headerFamily,
      tabSize: tabSize,
      faces: faces
    )
  }

  private static func cssPixels(_ value: Double) -> String {
    if value.rounded() == value {
      return "\(Int(value))px"
    }
    return "\(value)px"
  }

  private static func cssNumber(_ value: Double) -> String {
    if value.rounded() == value {
      return "\(Int(value))"
    }
    return "\(value)"
  }
}

/// Additional @pierre/diffs render options exposed by PierreDiffView.
///
/// Defaults preserve the wrapper's historical rendering behavior.
public struct PierreDiffRenderOptions: Codable, Sendable, Equatable {
  public var theme: PierreDiffTheme
  public var font: PierreDiffFont
  public var diffIndicators: DiffIndicatorStyle
  public var hunkSeparators: HunkSeparatorStyle
  public var lineDiffType: LineDiffType
  public var disableLineNumbers: Bool
  public var disableFileHeader: Bool
  public var disableBackground: Bool
  public var expandUnchanged: Bool
  public var collapsedContextThreshold: Int?
  public var maxLineDiffLength: Int?
  public var expansionLineCount: Int?
  public var tokenizeMaxLength: Int?
  public var tokenizeMaxLineLength: Int?
  public var stickyHeader: Bool

  public init(
    theme: PierreDiffTheme = .pierre,
    font: PierreDiffFont = .default,
    diffIndicators: DiffIndicatorStyle = .bars,
    hunkSeparators: HunkSeparatorStyle = .lineInfo,
    lineDiffType: LineDiffType = .wordAlt,
    disableLineNumbers: Bool = false,
    disableFileHeader: Bool = false,
    disableBackground: Bool = false,
    expandUnchanged: Bool = false,
    collapsedContextThreshold: Int? = nil,
    maxLineDiffLength: Int? = nil,
    expansionLineCount: Int? = nil,
    tokenizeMaxLength: Int? = nil,
    tokenizeMaxLineLength: Int? = nil,
    stickyHeader: Bool = false
  ) {
    self.theme = theme
    self.font = font
    self.diffIndicators = diffIndicators
    self.hunkSeparators = hunkSeparators
    self.lineDiffType = lineDiffType
    self.disableLineNumbers = disableLineNumbers
    self.disableFileHeader = disableFileHeader
    self.disableBackground = disableBackground
    self.expandUnchanged = expandUnchanged
    self.collapsedContextThreshold = collapsedContextThreshold
    self.maxLineDiffLength = maxLineDiffLength
    self.expansionLineCount = expansionLineCount
    self.tokenizeMaxLength = tokenizeMaxLength
    self.tokenizeMaxLineLength = tokenizeMaxLineLength
    self.stickyHeader = stickyHeader
  }
}
