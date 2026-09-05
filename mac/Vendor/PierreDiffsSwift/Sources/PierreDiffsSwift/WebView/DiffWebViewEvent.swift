//
//  DiffWebViewEvent.swift
//  PierreDiffsSwift
//
//  Created by James Rochabrun on 1/6/26.
//

import Foundation

/// Events sent from the JavaScript diff renderer to Swift.
enum DiffWebViewEvent {
  /// The JavaScript bridge is ready to receive commands
  case bridgeReady

  /// The diff has been rendered and is ready for interaction
  case ready

  /// A line was clicked (includes position for UI overlay positioning)
  case lineClicked(lineNumber: Int, side: String, lineY: CGFloat, lineHeight: CGFloat)

  /// Text selection changed
  case selectionChanged(startLine: Int, endLine: Int, side: String)

  /// An editable CodeView item's updated side changed.
  case fileEditChanged(fileID: String, contents: String)

  /// An edited CodeView item left edit mode.
  case fileEditCompleted(fileID: String, contents: String)

  /// System theme changed
  case systemThemeChanged(isDark: Bool)

  /// An annotation was clicked
  case annotationClicked(id: String, side: String, lineNumber: Int)

  /// An annotation delete was requested
  case annotationDeleteRequested(id: String, side: String, lineNumber: Int)

  /// An error occurred in the JavaScript layer
  case error(message: String)
}
