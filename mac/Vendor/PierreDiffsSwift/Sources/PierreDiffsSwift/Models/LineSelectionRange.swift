//
//  LineSelectionRange.swift
//  PierreDiffsSwift
//

import Foundation

/// Data about a multi-line selection (drag range) in the diff view.
/// Represents the range of lines selected when the user clicks and drags
/// across line numbers in the diff.
public struct LineSelectionRange: Sendable {
  /// The first line number in the selection
  public let startLine: Int

  /// The last line number in the selection
  public let endLine: Int

  /// Which side of the diff was selected ("left", "right", or "unified")
  public let side: String

  public init(startLine: Int, endLine: Int, side: String) {
    self.startLine = startLine
    self.endLine = endLine
    self.side = side
  }
}
