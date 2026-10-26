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

private func flatLayout(_ root: FileNode, size: CGSize = CGSize(width: 400, height: 400))
  -> [TreemapRect]
{
  TreemapLayout.layout(
    root: root, in: CGRect(origin: .zero, size: size), headerHeight: 0, padding: 0)
}

private func block(of node: FileNode, in rects: [TreemapRect]) throws -> CGRect {
  try #require(rects.first { $0.node === node && $0.kind == .block }).rect
}

/// Four equal files laid out as a 2 x 2 grid: a top left, b bottom left, c top right, d bottom
/// right (equal sizes keep the name order).
private func quad() -> (root: FileNode, a: FileNode, b: FileNode, c: FileNode, d: FileNode) {
  let a = file("a", 1000)
  let b = file("b", 1000)
  let c = file("c", 1000)
  let d = file("d", 1000)
  return (folder("root", [a, b, c, d]), a, b, c, d)
}

// MARK: Keyboard neighbors

@Test func neighborsOfAGridBlockAreTheAdjacentOnes() {
  let grid = quad()
  let rects = flatLayout(grid.root)
  #expect(TreemapNavigation.neighbor(of: grid.a, direction: .right, in: rects) === grid.c)
  #expect(TreemapNavigation.neighbor(of: grid.a, direction: .down, in: rects) === grid.b)
  #expect(TreemapNavigation.neighbor(of: grid.b, direction: .right, in: rects) === grid.d)
  #expect(TreemapNavigation.neighbor(of: grid.b, direction: .up, in: rects) === grid.a)
  #expect(TreemapNavigation.neighbor(of: grid.c, direction: .left, in: rects) === grid.a)
  #expect(TreemapNavigation.neighbor(of: grid.c, direction: .down, in: rects) === grid.d)
  #expect(TreemapNavigation.neighbor(of: grid.d, direction: .up, in: rects) === grid.c)
  #expect(TreemapNavigation.neighbor(of: grid.d, direction: .left, in: rects) === grid.b)
}

@Test func noNeighborAtTheEdges() {
  let grid = quad()
  let rects = flatLayout(grid.root)
  #expect(TreemapNavigation.neighbor(of: grid.a, direction: .left, in: rects) == nil)
  #expect(TreemapNavigation.neighbor(of: grid.a, direction: .up, in: rects) == nil)
  #expect(TreemapNavigation.neighbor(of: grid.c, direction: .right, in: rects) == nil)
  #expect(TreemapNavigation.neighbor(of: grid.b, direction: .down, in: rects) == nil)
}

@Test func neighborsAreSiblingsOnly() throws {
  // a (top) and f (bottom) hold x (top left) and y (bottom right) inside f.
  let x = file("x", 1000)
  let y = file("y", 1000)
  let f = folder("f", [x, y])
  let a = file("a", 2000)
  let root = folder("root", [a, f])
  let rects = flatLayout(root)
  #expect(try block(of: x, in: rects) == CGRect(x: 0, y: 200, width: 200, height: 200))
  // a sits above x, but it is not a sibling of x, so x has no neighbor above it.
  #expect(TreemapNavigation.neighbor(of: x, direction: .up, in: rects) == nil)
  #expect(TreemapNavigation.neighbor(of: x, direction: .right, in: rects) === y)
  #expect(TreemapNavigation.neighbor(of: a, direction: .down, in: rects) === f)
}

@Test func aBlockStraightAheadBeatsACloserOneFarToTheSide() {
  let o = file("o", 1)
  let near = file("near", 1)
  let straight = file("straight", 1)
  let root = folder("root", [o, near, straight])
  defer { withExtendedLifetime(root) {} }
  func rect(_ node: FileNode, _ x: CGFloat, _ y: CGFloat) -> TreemapRect {
    TreemapRect(
      node: node, rect: CGRect(x: x, y: y, width: 100, height: 100), depth: 1, kind: .block)
  }
  // `near` is 60 ahead but 200 to the side (score 460); `straight` is 300 ahead (score 300).
  let rects = [rect(o, 0, 0), rect(near, 60, 200), rect(straight, 300, 0)]
  #expect(TreemapNavigation.neighbor(of: o, direction: .right, in: rects) === straight)
}

@Test func folderBlocksHaveNeighborsWithHeadersAndPadding() {
  let f1 = folder("f1", [file("x1", 1000), file("y1", 1000)])
  let f2 = folder("f2", [file("x2", 900), file("y2", 900)])
  let root = folder("root", [f1, f2])
  let rects = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 400, height: 400))
  let toTheSide = TreemapNavigation.neighbor(of: f1, direction: .right, in: rects)
  let below = TreemapNavigation.neighbor(of: f1, direction: .down, in: rects)
  #expect(toTheSide === f2 || below === f2)
}

@Test func rootHasNoNeighbors() {
  let grid = quad()
  let rects = flatLayout(grid.root)
  #expect(TreemapNavigation.neighbor(of: grid.root, direction: .right, in: rects) == nil)
}

@Test func firstBlockIsTheLargestChild() {
  let grid = quad()
  let rects = flatLayout(grid.root)
  #expect(TreemapNavigation.firstBlock(under: grid.root, in: rects) === grid.a)
  let empty = folder("empty", [])
  #expect(TreemapNavigation.firstBlock(under: empty, in: flatLayout(empty)) == nil)
}

@Test func firstBlockUnderAZoomedFocusIsItsLargestChild() throws {
  let x = file("x", 1000)
  let y = file("y", 1000)
  let f = folder("f", [x, y])
  let rects = flatLayout(f)
  #expect(TreemapNavigation.firstBlock(under: f, in: rects) === x)
}

// MARK: Accessibility elements

@Test func accessibleBlocksExcludeTheFocus() {
  let grid = quad()
  let rects = flatLayout(grid.root)
  let blocks = TreemapNavigation.accessibleBlocks(in: rects, focus: grid.root)
  #expect(blocks.count == 4)
  #expect(!blocks.contains { $0.node === grid.root })
  #expect(Set(blocks.map(\.node.name)) == ["a", "b", "c", "d"])
}

@Test func accessibleBlocksAreCappedAndLargestFirst() {
  let children = (0..<60).map { file(String(format: "f%02d", $0), Int64(($0 + 1) * 1000)) }
  let root = folder("root", children)
  let rects = flatLayout(root)
  let blocks = TreemapNavigation.accessibleBlocks(in: rects, focus: root)
  #expect(blocks.count == 50)
  #expect(blocks.first?.node.name == "f59")
  let areas = blocks.map { $0.rect.width * $0.rect.height }
  #expect(zip(areas, areas.dropFirst()).allSatisfy { $0 >= $1 })
  #expect(TreemapNavigation.accessibleBlocks(in: rects, focus: root, limit: 3).count == 3)
}

@Test func accessibleBlockLabelsNameSizeAndCategory() {
  let photo = file("photo.jpg", 2048)
  let downloads = folder("Downloads", [file("x.bin", 4096)])
  let root = folder("root", [photo, downloads])
  let blocks = TreemapNavigation.accessibleBlocks(in: flatLayout(root), focus: root)
  let photoBlock = blocks.first { $0.node === photo }
  let folderBlock = blocks.first { $0.node === downloads }
  #expect(photoBlock?.label == "photo.jpg, \(ByteFormat.string(2048)), Photos")
  #expect(photoBlock?.isFolder == false)
  #expect(folderBlock?.label == "Downloads, \(ByteFormat.string(4096)), Folder")
  #expect(folderBlock?.isFolder == true)
}

@Test func accessibleBlocksLeaveOutSmallItems() {
  let tiny = (0..<200).map { file("t\($0)", 1) }
  let root = folder("root", [file("huge", 1_000_000)] + tiny)
  let rects = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 300, height: 300))
  #expect(rects.contains { $0.isSmallItems })
  let blocks = TreemapNavigation.accessibleBlocks(in: rects, focus: root)
  #expect(blocks.map(\.node.name) == ["huge"])
}

// MARK: Tooltip placement

@Test func tooltipGoesRightAndBelowTheCursor() {
  let origin = TooltipPlacement.origin(
    cursor: CGPoint(x: 100, y: 100), size: CGSize(width: 200, height: 36),
    bounds: CGSize(width: 1000, height: 800))
  #expect(origin == CGPoint(x: 114, y: 114))
}

@Test func tooltipFlipsLeftAtTheRightEdge() {
  let origin = TooltipPlacement.origin(
    cursor: CGPoint(x: 900, y: 100), size: CGSize(width: 200, height: 36),
    bounds: CGSize(width: 1000, height: 800))
  #expect(origin == CGPoint(x: 686, y: 114))
}

@Test func tooltipFlipsAboveAtTheBottomEdge() {
  let origin = TooltipPlacement.origin(
    cursor: CGPoint(x: 100, y: 780), size: CGSize(width: 200, height: 36),
    bounds: CGSize(width: 1000, height: 800))
  #expect(origin == CGPoint(x: 114, y: 730))
}

@Test func tooltipIsClampedAtTheTopLeft() {
  let origin = TooltipPlacement.origin(
    cursor: CGPoint(x: 10, y: 10), size: CGSize(width: 200, height: 36),
    bounds: CGSize(width: 100, height: 100))
  #expect(origin == CGPoint(x: 0, y: 24))
}

@Test func tooltipFlipsOnBothAxesInTheBottomRightCorner() {
  let origin = TooltipPlacement.origin(
    cursor: CGPoint(x: 900, y: 780), size: CGSize(width: 200, height: 36),
    bounds: CGSize(width: 1000, height: 800))
  #expect(origin == CGPoint(x: 686, y: 730))
}

@Test func tooltipLargerThanTheBoundsStaysAtTheTopLeftEdge() {
  let origin = TooltipPlacement.origin(
    cursor: CGPoint(x: 50, y: 50), size: CGSize(width: 200, height: 200),
    bounds: CGSize(width: 100, height: 100))
  #expect(origin == CGPoint(x: 0, y: 0))
}

// MARK: Small-items group

/// A 1 MB file and 200 tiny files of 1...200 bytes, so the tiny ones merge into one block.
private func smallItemsFixture() throws -> (root: FileNode, group: SmallItemsGroup) {
  let tiny = (0..<200).map { file("t\($0)", Int64($0 + 1)) }
  let root = folder("root", [file("huge", 1_000_000)] + tiny)
  let rects = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 300, height: 300))
  let merged = try #require(rects.first { $0.isSmallItems })
  return (root, try #require(SmallItemsGroup(rect: merged)))
}

@Test func smallItemsGroupMembersAreTheSmallestChildren() throws {
  let (root, group) = try smallItemsFixture()
  #expect(group.parent === root)
  #expect(group.count > 1 && group.count < 200)
  #expect(group.members.count == group.count)
  #expect(Set(group.members.map(\.size)) == Set((1...group.count).map { Int64($0) }))
  #expect(group.largest(5).map(\.size) == (0..<5).map { Int64(group.count - $0) })
  #expect(group.largest(5).count == 5)
  #expect(group.subtitle == "in root")
  #expect(group.title == "\(group.count.formatted()) small items")
}

@Test func smallItemsGroupTitleGroupsDigits() throws {
  let tiny = (0..<1200).map { file("t\($0)", 1) }
  let root = folder("node_modules", [file("huge", 1_000_000)] + tiny)
  let rects = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 300, height: 300))
  let group = try #require(rects.first { $0.isSmallItems }.flatMap(SmallItemsGroup.init(rect:)))
  #expect(group.count == 1200)
  #expect(group.title == "\(1200.formatted()) small items")
  #expect(group.subtitle == "in node_modules")
}

@Test func smallItemsGroupIsOnlyMadeFromSmallItemsRects() throws {
  let (root, _) = try smallItemsFixture()
  let rects = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 300, height: 300))
  let plain = try #require(rects.first { $0.kind == .block && $0.node.name == "huge" })
  #expect(SmallItemsGroup(rect: plain) == nil)
}
