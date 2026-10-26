import Foundation
import Testing

@testable import SpacerCore

/// /scan holds a readable folder b (with an unreadable b/x), an unreadable a, and a readable c.
private func makeTree() -> FileNode {
  let url = URL(fileURLWithPath: "/scan")
  let x = FileNode(
    name: "x", url: url.appendingPathComponent("b/x"), children: [], accessDenied: true)
  let okFile = FileNode(name: "ok.bin", url: url.appendingPathComponent("b/ok.bin"), size: 100)
  let b = FileNode(name: "b", url: url.appendingPathComponent("b"), children: [okFile, x])
  let a = FileNode(
    name: "a", url: url.appendingPathComponent("a"), children: [], accessDenied: true)
  let cFile = FileNode(name: "c.bin", url: url.appendingPathComponent("c/c.bin"), size: 50)
  let c = FileNode(name: "c", url: url.appendingPathComponent("c"), children: [cFile])
  return FileNode(name: "scan", url: url, children: [a, b, c])
}

@Suite struct UnreadableFoldersTests {
  @Test func walkFindsEveryUnreadableFolderAndNothingElse() {
    let root = makeTree()
    let names = root.unreadableFolders().map(\.name)
    #expect(Set(names) == ["a", "x"])
    #expect(names.count == 2)
  }

  @Test func walkOfAReadableTreeIsEmpty() {
    let file = FileNode(name: "f.bin", url: URL(fileURLWithPath: "/scan/f.bin"), size: 10)
    let root = FileNode(
      name: "scan", url: URL(fileURLWithPath: "/scan", isDirectory: true), children: [file])
    #expect(root.unreadableFolders().isEmpty)
  }

  @Test func unreadableRootIsItsOwnEntry() {
    let root = FileNode(
      name: "locked", url: URL(fileURLWithPath: "/locked", isDirectory: true), children: [],
      accessDenied: true)
    #expect(root.unreadableFolders().map(\.name) == ["locked"])
  }

  @Test func listIsSortedByPath() {
    let root = makeTree()
    let list = UnreadableFolders(root.unreadableFolders())
    #expect(list.nodes.map(\.url.path) == ["/scan/a", "/scan/b/x"])
    #expect(list.count == 2)
  }

  @Test func shownAndHiddenCountUseTheLimit() {
    let url = URL(fileURLWithPath: "/scan", isDirectory: true)
    let folders = (0..<25).map { index in
      FileNode(
        name: String(format: "f%02d", index),
        url: url.appendingPathComponent(String(format: "f%02d", index)), children: [],
        accessDenied: true)
    }
    let list = UnreadableFolders(folders)
    #expect(list.count == 25)
    #expect(list.shown(limit: 20).count == 20)
    #expect(list.shown(limit: 20).first?.name == "f00")
    #expect(list.shown(limit: 20).last?.name == "f19")
    #expect(list.hiddenCount(limit: 20) == 5)
    #expect(list.shown().count == 20)
    #expect(list.hiddenCount() == 5)
    #expect(list.shown(limit: 50).count == 25)
    #expect(list.hiddenCount(limit: 50) == 0)
  }

  @Test func countUnderCountsTheNodeAndItsDescendants() {
    let root = makeTree()
    let list = UnreadableFolders(root.unreadableFolders())
    let b = root.children.first { $0.name == "b" }
    let c = root.children.first { $0.name == "c" }
    #expect(list.countUnder(root) == 2)
    #expect(list.countUnder(b!) == 1)
    #expect(list.countUnder(c!) == 0)
  }

  @Test func warningTextForOneAndManyFoldersAndForTheRoot() {
    #expect(
      UnreadableFolders.warningText(count: 1, rootDenied: false, hasFullDiskAccess: false)
        == "1 folder couldn't be read. Grant Full Disk Access")
    #expect(
      UnreadableFolders.warningText(count: 3, rootDenied: false, hasFullDiskAccess: false)
        == "3 folders couldn't be read. Grant Full Disk Access")
    #expect(
      UnreadableFolders.warningText(count: 0, rootDenied: true, hasFullDiskAccess: false)
        == "Spacer couldn't read this location. Grant Full Disk Access and rescan.")
  }

  @Test func warningTextSaysMacOSProtectsFoldersWhenAccessIsGranted() {
    #expect(
      UnreadableFolders.warningText(count: 1, rootDenied: false, hasFullDiskAccess: true)
        == "1 folder couldn't be read. macOS protects it, so its size isn't counted.")
    #expect(
      UnreadableFolders.warningText(count: 3, rootDenied: false, hasFullDiskAccess: true)
        == "3 folders couldn't be read. macOS protects them, so their size isn't counted.")
    #expect(
      UnreadableFolders.warningText(count: 0, rootDenied: true, hasFullDiskAccess: true)
        == "Spacer couldn't read this location. macOS protects it.")
  }

  @Test func includesTextForOneAndManyFolders() {
    #expect(UnreadableFolders.includesText(count: 3) == "Includes 3 folders Spacer couldn't read")
    #expect(UnreadableFolders.includesText(count: 1) == "Includes 1 folder Spacer couldn't read")
  }

  @Test func moreTextNamesTheHiddenCount() {
    #expect(UnreadableFolders.moreText(hidden: 325) == "and 325 more")
  }
}
