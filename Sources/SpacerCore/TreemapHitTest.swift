import CoreGraphics
import Foundation

/// Finds what lies under a point in a laid-out treemap.
public enum TreemapHitTest {
  /// The deepest rect under `point`, or nil when the point is outside the map.
  ///
  /// `rects` must be in `TreemapLayout` order (parents before their children). Children sit
  /// inside their parent and siblings do not overlap, so the last rect that contains the point
  /// is the deepest one. Points in a folder's padding or title strip resolve to that folder.
  public static func rect(at point: CGPoint, in rects: [TreemapRect]) -> TreemapRect? {
    rects.last { $0.rect.contains(point) }
  }

  /// The node under `point` that can be hovered, selected and acted on. A "small items" block
  /// stands for several items, not for the folder that holds them, so it yields nil.
  public static func node(at point: CGPoint, in rects: [TreemapRect]) -> FileNode? {
    guard let hit = rect(at: point, in: rects), !hit.isSmallItems else { return nil }
    return hit.node
  }
}

extension TreemapRect {
  /// Identifies a rect across layouts of the same tree, so a view can animate between them.
  public struct Key: Hashable, Sendable {
    enum Tag: Hashable, Sendable { case block, folderHeader, smallItems }
    let node: ObjectIdentifier
    let tag: Tag
  }

  public var key: Key {
    let tag: Key.Tag =
      switch kind {
      case .block: .block
      case .folderHeader: .folderHeader
      case .smallItems: .smallItems
      }
    return Key(node: ObjectIdentifier(node), tag: tag)
  }

  /// A copy whose frame moves from `from` toward this rect's frame; `progress` runs 0...1.
  public func interpolated(from: CGRect, progress: Double) -> TreemapRect {
    let t = CGFloat(min(max(progress, 0), 1))
    func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
    let frame = CGRect(
      x: mix(from.minX, rect.minX), y: mix(from.minY, rect.minY),
      width: mix(from.width, rect.width), height: mix(from.height, rect.height))
    return TreemapRect(node: node, rect: frame, depth: depth, kind: kind)
  }
}
