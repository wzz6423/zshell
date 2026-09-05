//
//  PierreMultiDiffInput.swift
//  PierreDiffsSwift
//

import Foundation

/// One file in a multi-file diff surface.
///
/// A file normally carries both sides of its change. When the content cannot
/// be diffed at all — binary, too large, unreadable — pass `note` instead and
/// the file renders as a single-line entry holding that text, so it still
/// appears in the list with its header.
public struct PierreDiffFile: Codable, Sendable, Equatable, Identifiable {

  /// Stable identity used to scroll to this file and to reconcile updates.
  /// A repository-relative path is the natural choice.
  public let id: String

  /// The file's path or name, shown in its header and used for syntax
  /// highlighting detection.
  public let name: String

  /// Previous path when the change is a rename or copy; the "before" side is
  /// attributed to this path so the header reads as a rename.
  public let oldName: String?

  /// Original content (before changes). Empty for an added file.
  public let oldContents: String

  /// Updated content (after changes). Empty for a deleted file.
  public let newContents: String

  /// Language override for syntax highlighting; detected from `name` if nil.
  public let lang: String?

  /// Whether the updated side can be edited in place.
  ///
  /// Editing is opt-in and applies only to real diff rows. Note-only entries
  /// remain read-only even when this value is true.
  public let isEditable: Bool

  /// Stand-in text rendered instead of a diff. When set, `oldContents` and
  /// `newContents` are ignored.
  public let note: String?

  public init(
    id: String,
    name: String,
    oldName: String? = nil,
    oldContents: String = "",
    newContents: String = "",
    lang: String? = nil,
    isEditable: Bool = false,
    note: String? = nil
  ) {
    self.id = id
    self.name = name
    self.oldName = oldName
    self.oldContents = oldContents
    self.newContents = newContents
    self.lang = lang
    self.isEditable = isEditable
    self.note = note
  }

  /// A file that cannot be diffed, shown with an explanatory line.
  public static func note(id: String, name: String, _ note: String) -> PierreDiffFile {
    PierreDiffFile(id: id, name: name, note: note)
  }
}

/// Where a multi-file surface should scroll to.
///
/// `token` exists so repeating the same file re-triggers the scroll: SwiftUI
/// only forwards value changes, and asking twice for the same file is a normal
/// thing for a caller to do (clicking the same row in a file list again).
public struct PierreDiffScrollRequest: Sendable, Equatable {

  /// How the file is placed in the viewport once scrolled to.
  public enum Alignment: String, Sendable {
    case start
    case center
    case end
    case nearest
  }

  /// `id` of the `PierreDiffFile` to scroll to.
  public let fileID: String
  public let alignment: Alignment
  /// Animate the scroll instead of jumping.
  public let animated: Bool
  /// Changing this value re-runs the request for the same file.
  public let token: Int

  public init(
    fileID: String,
    alignment: Alignment = .start,
    animated: Bool = false,
    token: Int = 0
  ) {
    self.fileID = fileID
    self.alignment = alignment
    self.animated = animated
    self.token = token
  }
}

/// Input sent to the JavaScript `renderFiles` bridge.
struct PierreMultiDiffInput: Codable, Sendable {
  let files: [PierreDiffFile]
  let options: PierreDiffInput.Options
}

/// Input sent to the JavaScript `scrollToFile` bridge.
struct PierreScrollToFileInput: Codable, Sendable {
  let id: String
  let align: String
  let behavior: String

  init(_ request: PierreDiffScrollRequest) {
    self.id = request.fileID
    self.align = request.alignment.rawValue
    self.behavior = request.animated ? "smooth" : "instant"
  }
}
