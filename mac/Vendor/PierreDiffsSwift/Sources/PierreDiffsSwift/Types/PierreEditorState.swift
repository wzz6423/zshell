import Foundation

/// Serializable state from the pinned Pierre Editor, with its owning surface's scroll offset.
nonisolated public struct PierreEditorState: Codable, Equatable, Sendable {
  public struct Position: Codable, Equatable, Sendable {
    public var line: Int
    public var character: Int
    public init(line: Int, character: Int) { self.line = line; self.character = character }
  }
  public struct Selection: Codable, Equatable, Sendable {
    public var start: Position
    public var end: Position
    public var direction: Int
    public init(start: Position, end: Position, direction: Int) {
      self.start = start; self.end = end; self.direction = direction
    }
  }
  public struct View: Codable, Equatable, Sendable {
    public var scrollLeft: Double
    public init(scrollLeft: Double) { self.scrollLeft = scrollLeft }
  }
  public var selections: [Selection]?
  public var view: View?
  public var scrollTop: Double?

  public init(selections: [Selection]? = nil, view: View? = nil, scrollTop: Double? = nil) {
    self.selections = selections; self.view = view; self.scrollTop = scrollTop
  }

  public var isValid: Bool {
    (selections?.count ?? 0) <= 64
      && (selections ?? []).allSatisfy {
        $0.start.line >= 0 && $0.start.character >= 0 && $0.end.line >= 0 && $0.end.character >= 0
          && $0.start.line <= 5_242_880 && $0.end.line <= 5_242_880
          && $0.start.character <= 5_242_880 && $0.end.character <= 5_242_880
          && (-1...1).contains($0.direction)
      }
      && view.map { $0.scrollLeft.isFinite && $0.scrollLeft >= 0 && $0.scrollLeft <= 1e9 } != false
      && scrollTop.map { $0.isFinite && $0 >= 0 && $0 <= 1e9 } != false
  }
}
