//
//  DiffAnnotation.swift
//  PierreDiffsSwift
//
//  Created by James Rochabrun on 4/7/26.
//

import Foundation

/// Which side of the diff an annotation belongs to.
public enum AnnotationSide: String, Codable, Sendable {
  case deletions
  case additions
}

/// An annotation attached to a specific line in a diff.
/// Matches @pierre/diffs DiffLineAnnotation<T>.
public struct DiffAnnotation: Codable, Sendable, Equatable {
  public let side: AnnotationSide
  public let lineNumber: Int
  public let metadata: AnnotationMetadata

  public init(side: AnnotationSide, lineNumber: Int, metadata: AnnotationMetadata) {
    self.side = side
    self.lineNumber = lineNumber
    self.metadata = metadata
  }
}

/// Metadata for an inline comment annotation.
public struct AnnotationMetadata: Codable, Sendable, Equatable {
  public let id: String
  public let author: String
  public let body: String
  public let avatarURL: String?
  public let subtitle: String?

  public init(id: String = UUID().uuidString, author: String, body: String, avatarURL: String? = nil, subtitle: String? = nil) {
    self.id = id
    self.author = author
    self.body = body
    self.avatarURL = avatarURL
    self.subtitle = subtitle
  }
}
