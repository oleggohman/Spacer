import Foundation
import Testing

@testable import SpacerCore

@Suite struct FileNodeTests {
  /// A tree rooted at /scan with a file five levels down, at /scan/a/b/c/d.txt.
  private func deepTree() -> (root: FileNode, deep: FileNode) {
    let deep = FileNode(name: "d.txt", url: URL(fileURLWithPath: "/scan/a/b/c/d.txt"), size: 10)
    let c = FileNode(
      name: "c", url: URL(fileURLWithPath: "/scan/a/b/c", isDirectory: true), children: [deep])
    let b = FileNode(
      name: "b", url: URL(fileURLWithPath: "/scan/a/b", isDirectory: true), children: [c])
    let a = FileNode(
      name: "a", url: URL(fileURLWithPath: "/scan/a", isDirectory: true), children: [b])
    let root = FileNode(
      name: "scan", url: URL(fileURLWithPath: "/scan", isDirectory: true), children: [a])
    return (root, deep)
  }

  @Test func deepNodesBuildTheirPathFromTheRoot() {
    let (root, deep) = deepTree()
    #expect(deep.url == URL(fileURLWithPath: "/scan/a/b/c/d.txt"))
    #expect(deep.url.path == "/scan/a/b/c/d.txt")
    #expect(deep.ancestry.map(\.name) == ["scan", "a", "b", "c", "d.txt"])
    #expect(root.url.path == "/scan")
    #expect(root.children[0].children[0].url.path == "/scan/a/b")
  }

  @Test func folderPathsAreDirectoryURLs() {
    let (root, _) = deepTree()
    let a = root.children[0]
    #expect(a.url.hasDirectoryPath)
    #expect(a.url == URL(fileURLWithPath: "/scan/a", isDirectory: true))
  }

  @Test func removedNodeKeepsItsPath() {
    let (root, deep) = deepTree()
    let c = deep.parent!
    c.remove()
    #expect(c.parent == nil)
    #expect(c.url.path == "/scan/a/b/c")
    // The descendant builds its path through the removed node, which kept its own.
    #expect(deep.url.path == "/scan/a/b/c/d.txt")
    #expect(root.url.path == "/scan")
    #expect(root.children[0].children[0].children.isEmpty)
  }

  @Test func siblingsKeepTheirPathsAfterARemoval() {
    let first = FileNode(name: "1.bin", url: URL(fileURLWithPath: "/s/1.bin"), size: 1)
    let second = FileNode(name: "2.bin", url: URL(fileURLWithPath: "/s/2.bin"), size: 2)
    let root = FileNode(
      name: "s", url: URL(fileURLWithPath: "/s", isDirectory: true), children: [first, second])
    first.remove()
    #expect(first.url.path == "/s/1.bin")
    #expect(second.url.path == "/s/2.bin")
    #expect(root.children.map(\.url.path) == ["/s/2.bin"])
  }

  @Test func nodesAreIdentifiedByObjectNotPath() {
    let first = FileNode(name: "x", url: URL(fileURLWithPath: "/x"), size: 1)
    let second = FileNode(name: "x", url: URL(fileURLWithPath: "/x"), size: 1)
    #expect(first == first)
    #expect(first != second)
    #expect(Set([first, second]).count == 2)
  }

  @Test func categoryComesFromTheNameExtension() {
    // The path's extension differs from the name's, so only the name can give the category.
    let movie = FileNode(name: "clip.MOV", url: URL(fileURLWithPath: "/elsewhere/data"), size: 5)
    #expect(FileCategory.of(movie) == .video)
    for name in ["clip.MOV", ".bashrc", "archive.tar.gz", "file.", "noext", "Tool.app"] {
      #expect(
        (name as NSString).pathExtension == URL(fileURLWithPath: name).pathExtension,
        "\(name)")
    }
  }
}
