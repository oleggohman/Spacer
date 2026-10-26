import CoreGraphics
import Foundation

/// The keyboard and VoiceOver side of the treemap: which block an arrow key moves to, which
/// blocks VoiceOver lists, and where a tooltip goes. The rects must come from one layout.
public enum TreemapNavigation {
  public enum Direction: Sendable, Equatable {
    case up, down, left, right
  }

  /// The sibling block that lies in `direction` from `node`'s block, or nil when there is none.
  /// Siblings are the blocks that share `node`'s parent. Among those ahead of the block, the one
  /// with the smallest `along + 2 * across` wins, so a block straight ahead beats one far off to
  /// the side.
  public static func neighbor(
    of node: FileNode, direction: Direction, in rects: [TreemapRect]
  ) -> FileNode? {
    guard let parent = node.parent,
      let origin = rects.first(where: { $0.kind == .block && $0.node === node })?.rect
    else { return nil }
    var best: (node: FileNode, score: CGFloat)?
    for candidate in rects
    where candidate.kind == .block && candidate.node !== node && candidate.node.parent === parent {
      let dx = candidate.rect.midX - origin.midX
      let dy = candidate.rect.midY - origin.midY
      let (along, across): (CGFloat, CGFloat) =
        switch direction {
        case .right: (dx, dy)
        case .left: (-dx, dy)
        case .down: (dy, dx)
        case .up: (-dy, dx)
        }
      guard along > 0 else { continue }
      let score = along + 2 * abs(across)
      if best == nil || score < best!.score {
        best = (candidate.node, score)
      }
    }
    return best?.node
  }

  /// The largest child of `focus`, the block that Tab-then-arrow starts from when nothing is
  /// selected. Children are laid out largest first, so it is the first child block.
  public static func firstBlock(under focus: FileNode, in rects: [TreemapRect]) -> FileNode? {
    rects.first { $0.kind == .block && $0.node.parent === focus }?.node
  }

  /// The blocks VoiceOver offers for the map: every block except the focus, largest first, at
  /// most `limit`. Small-items blocks are left out. Recompute only when the layout changes.
  public static func accessibleBlocks(
    in rects: [TreemapRect], focus: FileNode, limit: Int = 50
  ) -> [AccessibleBlock] {
    rects
      .filter { $0.kind == .block && $0.node !== focus }
      .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
      .prefix(max(0, limit))
      .map(AccessibleBlock.init)
  }
}

/// One map block as VoiceOver sees it: a label to read and whether Zoom In applies.
public struct AccessibleBlock: Identifiable, Sendable {
  public let id: TreemapRect.Key
  public let node: FileNode
  public let rect: CGRect
  /// "Photos.app, 12.4 GB, Apps", or "Downloads, 3 GB, Folder" for a plain folder.
  public let label: String
  public let isFolder: Bool

  init(_ block: TreemapRect) {
    id = block.key
    node = block.node
    rect = block.rect
    isFolder = block.node.isDirectory
    let category =
      block.node.isDirectory && !block.node.isAppBundle
      ? "Folder" : FileCategory.of(block.node).displayName
    label = "\(block.node.name), \(ByteFormat.string(block.node.size)), \(category)"
  }
}

/// Where a hover tooltip goes: right of and below the cursor, flipped to the other side when it
/// would leave the map.
public enum TooltipPlacement {
  /// The tooltip's top-left corner. It flips left when it would cross `bounds.width`, above when
  /// it would cross `bounds.height`, and is clamped at 0 so it never leaves the top or left edge.
  public static func origin(
    cursor: CGPoint, size: CGSize, bounds: CGSize, offset: CGFloat = 14
  ) -> CGPoint {
    var x = cursor.x + offset
    if x + size.width > bounds.width { x = cursor.x - offset - size.width }
    var y = cursor.y + offset
    if y + size.height > bounds.height { y = cursor.y - offset - size.height }
    return CGPoint(x: max(0, x), y: max(0, y))
  }
}
