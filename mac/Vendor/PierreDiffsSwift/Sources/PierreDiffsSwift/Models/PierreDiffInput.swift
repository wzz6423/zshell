//
//  PierreDiffInput.swift
//  PierreDiffsSwift
//
//  Created by James Rochabrun on 1/6/26.
//

import Foundation

/// Input data structure for rendering diffs with @pierre/diffs.
/// This matches the JavaScript library's expected format.
public struct PierreDiffInput: Codable, Sendable {

  /// Represents a file's contents for diff comparison.
  public struct FileContents: Codable, Sendable {
    /// The filename (used for display and language detection)
    public let name: String

    /// The file's text content
    public let contents: String

    /// Optional language override for syntax highlighting.
    /// If nil, language is auto-detected from filename.
    public let lang: String?

    public init(name: String, contents: String, lang: String? = nil) {
      self.name = name
      self.contents = contents
      self.lang = lang
    }
  }

  /// Configuration options for the diff renderer.
  public struct Options: Codable, Sendable {
    /// Theme configuration for dark/light modes
    public let theme: ThemeConfig

    /// Current theme type: "dark" or "light"
    public let themeType: String?

    /// Diff view style: "split" or "unified"
    public let diffStyle: String

    /// Overflow mode: "scroll" or "wrap"
    public let overflow: String

    /// Enable click-to-select on line numbers
    public let enableLineSelection: Bool

    /// How changed lines are marked: "classic", "bars", or "none"
    public let diffIndicators: String

    /// Hunk separator style
    public let hunkSeparators: String

    /// Inline line diff style
    public let lineDiffType: String

    /// Hide line numbers
    public let disableLineNumbers: Bool

    /// Hide the file header
    public let disableFileHeader: Bool

    /// Disable changed-line background fills
    public let disableBackground: Bool

    /// Expand unchanged hunks
    public let expandUnchanged: Bool

    /// Collapse context threshold
    public let collapsedContextThreshold: Int?

    /// Maximum line length for inline diffing
    public let maxLineDiffLength: Int?

    /// Number of lines to expand when expanding a hunk
    public let expansionLineCount: Int?

    /// Maximum total tokenization length before falling back to plain text
    public let tokenizeMaxLength: Int?

    /// Maximum per-line tokenization length before falling back to plain text
    public let tokenizeMaxLineLength: Int?

    /// Stick file headers while scrolling
    public let stickyHeader: Bool

    /// Font configuration applied as CSS custom properties
    public let font: PierreDiffFont

    public init(
      theme: ThemeConfig,
      themeType: String? = nil,
      diffStyle: String,
      overflow: String,
      enableLineSelection: Bool,
      renderOptions: PierreDiffRenderOptions = PierreDiffRenderOptions()
    ) {
      self.theme = theme
      self.themeType = themeType
      self.diffStyle = diffStyle
      self.overflow = overflow
      self.enableLineSelection = enableLineSelection
      self.diffIndicators = renderOptions.diffIndicators.rawValue
      self.hunkSeparators = renderOptions.hunkSeparators.rawValue
      self.lineDiffType = renderOptions.lineDiffType.rawValue
      self.disableLineNumbers = renderOptions.disableLineNumbers
      self.disableFileHeader = renderOptions.disableFileHeader
      self.disableBackground = renderOptions.disableBackground
      self.expandUnchanged = renderOptions.expandUnchanged
      self.collapsedContextThreshold = renderOptions.collapsedContextThreshold
      self.maxLineDiffLength = renderOptions.maxLineDiffLength
      self.expansionLineCount = renderOptions.expansionLineCount
      self.tokenizeMaxLength = renderOptions.tokenizeMaxLength
      self.tokenizeMaxLineLength = renderOptions.tokenizeMaxLineLength
      self.stickyHeader = renderOptions.stickyHeader
      self.font = renderOptions.font
    }
  }

  /// Theme configuration supporting dark and light modes.
  public struct ThemeConfig: Codable, Sendable {
    /// Theme name for dark mode (e.g., "pierre-dark")
    public let dark: String

    /// Theme name for light mode (e.g., "pierre-light")
    public let light: String

    public init(dark: String, light: String) {
      self.dark = dark
      self.light = light
    }

    public init(_ theme: PierreDiffTheme) {
      self.dark = theme.dark
      self.light = theme.light
    }
  }

  /// The original file (before changes)
  public let oldFile: FileContents

  /// The new file (after changes)
  public let newFile: FileContents

  /// Rendering options
  public let options: Options

  /// Optional line annotations for inline comments
  public let lineAnnotations: [DiffAnnotation]?

  public init(oldFile: FileContents, newFile: FileContents, options: Options, lineAnnotations: [DiffAnnotation]? = nil) {
    self.oldFile = oldFile
    self.newFile = newFile
    self.options = options
    self.lineAnnotations = lineAnnotations
  }
}

// MARK: - Convenience Initializers

extension PierreDiffInput {

  /// Creates a PierreDiffInput from a DiffResult.
  ///
  /// - Parameters:
  ///   - diffResult: The diff result containing original and updated content
  ///   - diffStyle: The style to use for rendering
  ///   - overflowMode: The overflow mode (scroll or wrap)
  /// - Returns: A configured PierreDiffInput
  public static func from(
    diffResult: DiffResult,
    diffStyle: DiffStyle = .split,
    overflowMode: OverflowMode = .scroll,
    renderOptions: PierreDiffRenderOptions = PierreDiffRenderOptions()
  ) -> PierreDiffInput {
    PierreDiffInput(
      oldFile: FileContents(
        name: diffResult.fileName,
        contents: diffResult.original,
        lang: nil
      ),
      newFile: FileContents(
        name: diffResult.fileName,
        contents: diffResult.updated,
        lang: nil
      ),
      options: Options(
        theme: ThemeConfig(renderOptions.theme),
        diffStyle: diffStyle.rawValue,
        overflow: overflowMode.rawValue,
        enableLineSelection: true,
        renderOptions: renderOptions
      )
    )
  }
}
