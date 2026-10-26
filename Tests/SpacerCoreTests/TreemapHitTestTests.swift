import CoreGraphics
import Foundation
import Testing

@testable import SpacerCore

private func file(_ name: String, _ size: Int64) -> FileNode {
  FileNode(name: name, url: URL(fileURLWithPath: "/t/\(name)"), size: size)
}

private func folder(_ name: String, _ children: [FileNode]) -> FileNode {
  FileNode(
    name: name, url: URL(fileURLWithPath: "/t/\(name)", isDirectory: true), children: children)
}

private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

private func blockRect(of node: FileNode, in rects: [TreemapRect]) throws -> CGRect {
  try #require(rects.first { $0.node === node && $0.kind == .block }).rect
}

@Test func deepestNodeIsReturned() throws {
  let leaf = file("leaf", 100)
  let inner = folder("inner", [leaf, file("other", 50)])
  let root = folder("root", [inner, file("top", 80)])
  let rects = TreemapLayout.layout(root: root, in: bounds)

  let leafFrame = try blockRect(of: leaf, in: rects)
  #expect(TreemapHitTest.node(at: center(leafFrame), in: rects) === leaf)
  let hit = try #require(TreemapHitTest.rect(at: center(leafFrame), in: rects))
  #expect(hit.depth == 2)
  #expect(hit.kind == .block)
}

@Test func headerStripResolvesToFolder() throws {
  let inner = folder("inner", [file("a", 100), file("b", 50)])
  let root = folder("root", [inner, file("top", 80)])
  let rects = TreemapLayout.layout(root: root, in: bounds)

  let header = try #require(rects.first { $0.node === inner && $0.isFolderHeader })
  #expect(TreemapHitTest.node(at: center(header.rect), in: rects) === inner)

  let rootHeader = try #require(rects.first { $0.node === root && $0.isFolderHeader })
  #expect(TreemapHitTest.node(at: center(rootHeader.rect), in: rects) === root)
}

@Test func paddingGapResolvesToFolder() throws {
  let inner = folder("inner", [file("a", 100), file("b", 50)])
  let root = folder("root", [inner, file("top", 80)])
  let rects = TreemapLayout.layout(root: root, in: bounds, padding: 6)

  let frame = try blockRect(of: inner, in: rects)
  // Inside the folder's left padding, below its title strip.
  let gap = CGPoint(x: frame.minX + 2, y: frame.midY)
  #expect(TreemapHitTest.node(at: gap, in: rects) === inner)
  // The bottom padding of the root, below every child.
  let bottom = CGPoint(x: bounds.midX, y: bounds.maxY - 2)
  #expect(TreemapHitTest.node(at: bottom, in: rects) === root)
}

@Test func pointsOutsideReturnNil() {
  let root = folder("root", [file("a", 100)])
  let rects = TreemapLayout.layout(root: root, in: bounds)

  #expect(TreemapHitTest.rect(at: CGPoint(x: -1, y: 10), in: rects) == nil)
  #expect(TreemapHitTest.rect(at: CGPoint(x: 10, y: 301), in: rects) == nil)
  #expect(TreemapHitTest.node(at: CGPoint(x: 500, y: 500), in: rects) == nil)
  #expect(TreemapHitTest.node(at: .zero, in: []) == nil)
}

@Test func smallItemsHitTheirRectButNoSelectableNode() throws {
  var children = [file("big", 1_000_000)]
  children += (0..<20).map { file("tiny\($0)", 1) }
  let root = folder("root", children)
  let rects = TreemapLayout.layout(root: root, in: bounds, minSide: 8)

  let merged = try #require(rects.first { $0.isSmallItems })
  let hit = try #require(TreemapHitTest.rect(at: center(merged.rect), in: rects))
  #expect(hit.isSmallItems)
  #expect(hit.node === root)
  #expect(TreemapHitTest.node(at: center(merged.rect), in: rects) == nil)
}

@Test func interpolationMovesTowardTheTarget() {
  let node = file("a", 10)
  let target = TreemapRect(
    node: node, rect: CGRect(x: 100, y: 100, width: 200, height: 100), depth: 1, kind: .block)
  let from = CGRect(x: 0, y: 0, width: 100, height: 50)

  #expect(target.interpolated(from: from, progress: 0).rect == from)
  #expect(target.interpolated(from: from, progress: 1).rect == target.rect)
  #expect(
    target.interpolated(from: from, progress: 0.5).rect
      == CGRect(x: 50, y: 50, width: 150, height: 75))
  #expect(target.interpolated(from: from, progress: 2).rect == target.rect)

  let header = TreemapRect(node: node, rect: .zero, depth: 1, kind: .folderHeader)
  #expect(target.key != header.key)
  #expect(target.key == target.interpolated(from: from, progress: 0.3).key)
}
