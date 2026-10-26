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

private func area(_ rect: CGRect) -> Double { Double(rect.width * rect.height) }

private func aspect(_ rect: CGRect) -> Double {
  Double(max(rect.width, rect.height) / min(rect.width, rect.height))
}

private func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 1e-6) -> Bool {
  inner.minX >= outer.minX - tolerance && inner.minY >= outer.minY - tolerance
    && inner.maxX <= outer.maxX + tolerance && inner.maxY <= outer.maxY + tolerance
}

private func blocks(_ rects: [TreemapRect]) -> [TreemapRect] {
  rects.filter { $0.kind == .block }
}

private func sampleTree() -> FileNode {
  folder(
    "root",
    [
      folder(
        "a", [file("a1", 500), file("a2", 300), folder("a3", [file("x", 120), file("y", 80)])]),
      folder("b", [file("b1", 400), file("b2", 100)]),
      file("c", 250),
      file("d", 150),
    ])
}

@Suite struct TreemapLayoutTests {
  let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

  @Test func childAreasAreProportionalToSize() {
    let root = folder("root", [file("a", 400), file("b", 300), file("c", 200), file("d", 100)])
    let rects = TreemapLayout.layout(root: root, in: bounds, headerHeight: 0, padding: 0)
    let children = blocks(rects).filter { $0.depth == 1 }
    #expect(children.count == 4)
    let total = area(bounds)
    for item in children {
      let expected = total * Double(item.node.size) / Double(root.size)
      #expect(abs(area(item.rect) - expected) < expected * 1e-6)
    }
  }

  @Test func childAreasStayProportionalWithHeaders() {
    let rects = TreemapLayout.layout(root: sampleTree(), in: bounds)
    let rootContent = CGRect(
      x: 2, y: 18, width: bounds.width - 4, height: bounds.height - 16 - 4)
    let children = blocks(rects).filter { $0.depth == 1 }
    let sum = children.reduce(0.0) { $0 + area($1.rect) }
    #expect(abs(sum - area(rootContent)) < 1e-6)
    for item in children {
      let expected = area(rootContent) * Double(item.node.size) / Double(sampleTree().size)
      #expect(abs(area(item.rect) - expected) < expected * 1e-6)
    }
  }

  @Test func rectsStayInsideTheirParent() {
    let rects = TreemapLayout.layout(root: sampleTree(), in: bounds)
    let frames = Dictionary(
      blocks(rects).map { ($0.node.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
    for item in rects {
      #expect(contains(bounds, item.rect))
      guard item.depth > 0 else { continue }
      let parent = item.isSmallItems ? item.node : item.node.parent!
      if item.kind == .folderHeader { continue }
      #expect(contains(frames[parent.id]!, item.rect), "\(item.node.name) escapes its parent")
    }
  }

  @Test func headersSitAtTheTopOfTheirFolder() {
    let rects = TreemapLayout.layout(root: sampleTree(), in: bounds)
    let headers = rects.filter(\.isFolderHeader)
    #expect(!headers.isEmpty)
    for header in headers {
      let block = blocks(rects).first { $0.node === header.node }!
      #expect(header.rect.minY == block.rect.minY)
      #expect(header.rect.width == block.rect.width)
      #expect(header.rect.height == TreemapLayout.defaultHeaderHeight)
      #expect(header.depth == block.depth)
    }
    // No child block overlaps a header strip of its parent.
    for item in blocks(rects) where item.depth > 0 {
      let header = headers.first { $0.node === item.node.parent }!
      #expect(
        item.rect.intersection(header.rect).isNull
          || area(item.rect.intersection(header.rect)) < 1e-9)
    }
  }

  @Test func siblingsDoNotOverlap() {
    let rects = TreemapLayout.layout(root: sampleTree(), in: bounds).filter { !$0.isFolderHeader }
    let groups = Dictionary(grouping: rects.filter { $0.depth > 0 }) { item in
      item.isSmallItems ? item.node.id : item.node.parent!.id
    }
    for siblings in groups.values {
      for i in siblings.indices {
        for j in siblings.indices where j > i {
          let overlap = siblings[i].rect.intersection(siblings[j].rect)
          #expect(overlap.isNull || area(overlap) < 1e-6)
        }
      }
    }
  }

  @Test func aspectRatiosStayReasonable() {
    // The example from the Bruls et al. paper: areas 6, 6, 4, 3, 2, 2, 1 in a 6 x 4 rectangle.
    let sizes: [Int64] = [6, 6, 4, 3, 2, 2, 1]
    let root = folder("root", sizes.enumerated().map { file("f\($0.offset)", $0.element * 100) })
    let rects = TreemapLayout.layout(
      root: root, in: CGRect(x: 0, y: 0, width: 600, height: 400), minSide: 1, headerHeight: 0,
      padding: 0)
    let children = blocks(rects).filter { $0.depth == 1 }
    #expect(children.count == sizes.count)
    for item in children {
      #expect(aspect(item.rect) <= 3, "\(item.node.name) aspect \(aspect(item.rect))")
    }

    // Many equal items in a square should come out close to squares.
    let even = folder("even", (0..<16).map { file("e\($0)", 1000) })
    let evenRects = blocks(
      TreemapLayout.layout(
        root: even, in: CGRect(x: 0, y: 0, width: 400, height: 400), headerHeight: 0, padding: 0)
    ).filter { $0.depth == 1 }
    #expect(evenRects.count == 16)
    #expect(evenRects.allSatisfy { aspect($0.rect) < 2 })
  }

  @Test func zeroSizeAndEmptyFoldersAreHandled() {
    let root = folder("root", [file("big", 1000), file("zero", 0), folder("empty", [])])
    let rects = TreemapLayout.layout(root: root, in: bounds)
    #expect(!rects.contains { $0.node.name == "zero" })
    #expect(!rects.contains { $0.node.name == "empty" })
    #expect(blocks(rects).filter { $0.depth == 1 }.map(\.node.name) == ["big"])

    // An empty or zero-size root still shows its own block and title strip, but nothing inside.
    let emptyRoot = folder("emptyRoot", [file("z", 0)])
    let emptyRects = TreemapLayout.layout(root: emptyRoot, in: bounds)
    #expect(emptyRects.count == 2)
    #expect(emptyRects.map(\.kind) == [.block, .folderHeader])
    #expect(emptyRects[0].rect == bounds)

    #expect(TreemapLayout.layout(root: root, in: .zero).isEmpty)
    #expect(TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 100, height: 0)).isEmpty)
  }

  @Test func singleFileRootFillsTheBounds() {
    let rects = TreemapLayout.layout(root: file("solo", 42), in: bounds)
    #expect(rects.count == 1)
    #expect(rects[0].rect == bounds)
    #expect(rects[0].kind == .block)
  }

  @Test func depthLimitIsRespected() {
    let tree = sampleTree()
    let shallow = TreemapLayout.layout(root: tree, in: bounds, maxDepth: 1)
    #expect(shallow.allSatisfy { $0.depth <= 1 })
    #expect(shallow.contains { $0.depth == 1 })

    let rootOnly = TreemapLayout.layout(root: tree, in: bounds, maxDepth: 0)
    #expect(rootOnly.allSatisfy { $0.depth == 0 })

    let full = TreemapLayout.layout(root: tree, in: bounds)
    #expect(full.map(\.depth).max() == 3)
  }

  @Test func smallBlocksAreNotSubdivided() {
    let tree = sampleTree()
    let tiny = CGRect(x: 0, y: 0, width: 20, height: 20)
    let rects = TreemapLayout.layout(root: tree, in: tiny, minSide: 4)
    // 20pt is too short for a 16pt title strip plus padding plus a 4pt body.
    #expect(rects.count == 1)
    #expect(rects[0].node === tree)
  }

  @Test func smallItemsAreMerged() {
    let tinyFiles = (0..<200).map { file("t\($0)", 1) }
    let root = folder("root", [file("huge", 1_000_000)] + tinyFiles)
    let rects = TreemapLayout.layout(
      root: root, in: CGRect(x: 0, y: 0, width: 300, height: 300), minSide: 4)
    let merged = rects.filter(\.isSmallItems)
    #expect(merged.count == 1)
    #expect(merged.first?.kind == .smallItems(count: 200, size: 200))
    #expect(merged.first?.node === root)
    #expect(merged.first?.depth == 1)
    #expect(!rects.contains { $0.node.name.hasPrefix("t") })
    #expect(blocks(rects).filter { $0.depth == 1 }.map(\.node.name) == ["huge"])
  }

  @Test func aSingleSmallItemIsNotMerged() {
    let root = folder("root", [file("huge", 1_000_000), file("tiny", 1)])
    let rects = TreemapLayout.layout(
      root: root, in: CGRect(x: 0, y: 0, width: 300, height: 300), minSide: 4)
    #expect(!rects.contains { $0.isSmallItems })
    #expect(rects.contains { $0.node.name == "tiny" })
  }

  @Test func squarifyCoversTheRectangle() {
    let rect = CGRect(x: 10, y: 20, width: 300, height: 200)
    let areas: [Double] = [20000, 15000, 10000, 8000, 5000, 2000]
    let frames = TreemapLayout.squarify(areas, in: rect)
    #expect(frames.count == areas.count)
    let covered = frames.reduce(0.0) { $0 + area($1) }
    #expect(abs(covered - area(rect)) < 1e-6)
    for (frame, expected) in zip(frames, areas) {
      #expect(abs(area(frame) - expected) < 1e-6)
      #expect(contains(rect, frame))
    }
    #expect(TreemapLayout.squarify([], in: rect).isEmpty)
  }
}
