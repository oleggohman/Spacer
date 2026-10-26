import CoreGraphics
import Foundation

/// One rectangle produced by `TreemapLayout`.
public struct TreemapRect: Sendable {
  public enum Kind: Sendable, Equatable {
    /// The whole block of a file or folder. A folder's children are drawn on top of it.
    case block
    /// The title strip at the top of a folder block.
    case folderHeader
    /// Several tiny children merged into one block. `node` is their parent folder.
    case smallItems(count: Int, size: Int64)
  }

  public let node: FileNode
  /// Coordinates use a top-left origin, as SwiftUI does.
  public let rect: CGRect
  /// Depth below the layout root, which is depth 0.
  public let depth: Int
  public let kind: Kind

  public var isFolderHeader: Bool { kind == .folderHeader }
  public var isSmallItems: Bool {
    if case .smallItems = kind { return true }
    return false
  }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk) with SpaceMonger-style folder title strips.
public enum TreemapLayout {
  public static let defaultHeaderHeight: CGFloat = 16
  public static let defaultPadding: CGFloat = 2

  /// Lays out `root` inside `bounds` and returns every rect, parents before their children.
  ///
  /// - Parameters:
  ///   - maxDepth: children are laid out only for nodes shallower than this depth.
  ///   - minSide: blocks with a side shorter than this are not subdivided, and children whose
  ///     area would be under `minSide * minSide` are merged into one "N small items" block.
  public static func layout(
    root: FileNode, in bounds: CGRect, maxDepth: Int = .max, minSide: CGFloat = 4,
    headerHeight: CGFloat = defaultHeaderHeight, padding: CGFloat = defaultPadding
  ) -> [TreemapRect] {
    guard bounds.width > 0, bounds.height > 0 else { return [] }
    var builder = Builder(
      maxDepth: maxDepth, minSide: max(minSide, 0), headerHeight: max(headerHeight, 0),
      padding: max(padding, 0))
    builder.place(root, in: bounds, depth: 0)
    return builder.rects
  }

  private struct Builder {
    let maxDepth: Int
    let minSide: CGFloat
    let headerHeight: CGFloat
    let padding: CGFloat
    var rects: [TreemapRect] = []

    mutating func place(_ node: FileNode, in rect: CGRect, depth: Int) {
      rects.append(TreemapRect(node: node, rect: rect, depth: depth, kind: .block))
      guard node.isDirectory else { return }

      // A folder gets a title strip only when there is room for it and at least a minimal body.
      let bodyWidth = rect.width - 2 * padding
      let bodyHeight = rect.height - headerHeight - 2 * padding
      guard bodyWidth >= max(minSide, 1), bodyHeight >= max(minSide, 1) else { return }
      if headerHeight > 0 {
        let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
        rects.append(TreemapRect(node: node, rect: header, depth: depth, kind: .folderHeader))
      }
      guard depth < maxDepth else { return }

      let content = CGRect(
        x: rect.minX + padding, y: rect.minY + headerHeight + padding, width: bodyWidth,
        height: bodyHeight)
      layoutChildren(of: node, in: content, depth: depth + 1)
    }

    private mutating func layoutChildren(of node: FileNode, in content: CGRect, depth: Int) {
      let children = node.children.filter { $0.size > 0 }
      let total = children.reduce(Int64(0)) { $0 + $1.size }
      guard total > 0 else { return }

      let scale = Double(content.width * content.height) / Double(total)
      let minArea = Double(minSide * minSide)

      // Children are sorted largest first, so the tiny ones form a tail.
      var keepCount = children.count
      while keepCount > 0, Double(children[keepCount - 1].size) * scale < minArea {
        keepCount -= 1
      }
      let tail = children[keepCount...]
      let merge = tail.count >= 2
      let kept = merge ? Array(children[..<keepCount]) : children

      var areas = kept.map { Double($0.size) * scale }
      var tailSize: Int64 = 0
      if merge {
        tailSize = tail.reduce(Int64(0)) { $0 + $1.size }
        areas.append(Double(tailSize) * scale)
      }

      let frames = TreemapLayout.squarify(areas, in: content)
      for (child, frame) in zip(kept, frames) {
        place(child, in: frame, depth: depth)
      }
      if merge, let frame = frames.last {
        rects.append(
          TreemapRect(
            node: node, rect: frame, depth: depth,
            kind: .smallItems(count: tail.count, size: tailSize)))
      }
    }
  }

  /// Splits `rect` into one frame per area, using the squarified algorithm.
  /// The areas should be sorted largest first and add up to the area of `rect`.
  static func squarify(_ areas: [Double], in rect: CGRect) -> [CGRect] {
    var frames: [CGRect] = []
    frames.reserveCapacity(areas.count)
    var remaining = rect
    var index = 0

    while index < areas.count {
      let side = Double(min(remaining.width, remaining.height))
      var row = [areas[index]]
      var rowSum = areas[index]
      var next = index + 1
      while next < areas.count {
        let candidate = areas[next]
        if worstAspect(row + [candidate], sum: rowSum + candidate, side: side)
          > worstAspect(row, sum: rowSum, side: side)
        {
          break
        }
        row.append(candidate)
        rowSum += candidate
        next += 1
      }

      let isLastRow = next == areas.count
      if remaining.width >= remaining.height {
        // A column along the left edge.
        let height = Double(remaining.height)
        let thickness = isLastRow ? Double(remaining.width) : (height > 0 ? rowSum / height : 0)
        var y = Double(remaining.minY)
        for (offset, area) in row.enumerated() {
          let h =
            offset == row.count - 1
            ? Double(remaining.maxY) - y : (rowSum > 0 ? height * area / rowSum : 0)
          frames.append(
            CGRect(x: Double(remaining.minX), y: y, width: thickness, height: max(h, 0)))
          y += h
        }
        remaining = CGRect(
          x: Double(remaining.minX) + thickness, y: Double(remaining.minY),
          width: max(Double(remaining.width) - thickness, 0), height: height)
      } else {
        // A row along the top edge.
        let width = Double(remaining.width)
        let thickness = isLastRow ? Double(remaining.height) : (width > 0 ? rowSum / width : 0)
        var x = Double(remaining.minX)
        for (offset, area) in row.enumerated() {
          let w =
            offset == row.count - 1
            ? Double(remaining.maxX) - x : (rowSum > 0 ? width * area / rowSum : 0)
          frames.append(
            CGRect(x: x, y: Double(remaining.minY), width: max(w, 0), height: thickness))
          x += w
        }
        remaining = CGRect(
          x: Double(remaining.minX), y: Double(remaining.minY) + thickness, width: width,
          height: max(Double(remaining.height) - thickness, 0))
      }
      index = next
    }
    return frames
  }

  /// The worst aspect ratio in a row laid along a side of length `side`.
  static func worstAspect(_ row: [Double], sum: Double, side: Double) -> Double {
    guard sum > 0, side > 0, let largest = row.max(), let smallest = row.min(), smallest > 0
    else { return .infinity }
    let sideSquared = side * side
    let sumSquared = sum * sum
    return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
  }
}
