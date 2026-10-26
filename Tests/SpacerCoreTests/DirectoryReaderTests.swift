import Foundation
import Testing

@testable import SpacerCore

@Suite struct DirectoryReaderTests {
  @Test func readsKindsSizesAndLinks() throws {
    let tree = try TempTree()
    let file = try tree.file("a.bin", bytes: 10_000)
    try tree.folder("sub")
    try FileManager.default.createSymbolicLink(
      at: tree.root.appendingPathComponent("link"), withDestinationURL: file)
    try FileManager.default.linkItem(at: file, to: tree.root.appendingPathComponent("hard.bin"))

    let entries = try #require(DirectoryReader.entries(atPath: tree.root.path))
    let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

    #expect(Set(byName.keys) == ["a.bin", "sub", "link", "hard.bin"])
    let a = try #require(byName["a.bin"])
    #expect(a.kind == .file)
    #expect(a.allocatedSize == (try tree.allocatedSize(file)))
    #expect(a.linkCount == 2)
    #expect(byName["hard.bin"]?.inode == a.inode)
    #expect(byName["hard.bin"]?.device == a.device)
    #expect(byName["sub"]?.kind == .directory)
    #expect(byName["sub"]?.allocatedSize == 0)
    #expect(byName["sub"]?.isMountPoint == false)
    #expect(byName["link"]?.kind == .symbolicLink)
  }

  @Test(.enabled(if: TempTree.isAPFS)) func readsCloneAttributes() throws {
    let tree = try TempTree()
    let base = try tree.randomFile("base.bin", bytes: 1_048_576)
    try tree.clone(base, to: tree.root.appendingPathComponent("clone.bin"))
    try tree.file("solo.bin", bytes: 1_048_576)

    let entries = try #require(DirectoryReader.entries(atPath: tree.root.path))
    let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

    let original = try #require(byName["base.bin"])
    let clone = try #require(byName["clone.bin"])
    let solo = try #require(byName["solo.bin"])
    // A file that is not a clone has its own inode as clone ID, and so does the original.
    #expect(original.cloneID == original.inode)
    #expect(solo.cloneID == solo.inode)
    #expect(!original.isClone && !solo.isClone)
    #expect(original.privateSize == nil && solo.privateSize == nil)
    // A clone has the original's ID, and its private size is read for it alone.
    #expect(clone.cloneID == original.cloneID)
    #expect(clone.isClone)
    #expect(clone.privateSize == 0)
    #expect(clone.countedSize == 0)
    #expect(original.countedSize == original.allocatedSize)
    #expect(
      DirectoryReader.privateSize(atPath: tree.root.appendingPathComponent("clone.bin").path) == 0)
    #expect(
      DirectoryReader.privateSize(atPath: tree.root.appendingPathComponent("nope").path) == nil)
  }

  @Test func readsFoldersLargerThanOneBuffer() throws {
    let tree = try TempTree()
    for i in 0..<1_500 {
      try tree.file("file-with-a-longish-name-\(i).txt", bytes: 1)
    }
    let entries = try #require(DirectoryReader.entries(atPath: tree.root.path))
    #expect(entries.count == 1_500)
    #expect(Set(entries.map(\.name)).count == 1_500)
  }

  @Test func emptyFolderHasNoEntries() throws {
    let tree = try TempTree()
    #expect(DirectoryReader.entries(atPath: tree.root.path) == [])
  }

  @Test func unreadableOrMissingFoldersReturnNil() throws {
    let tree = try TempTree()
    let locked = try tree.folder("locked")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

    #expect(DirectoryReader.entries(atPath: locked.path) == nil)
    #expect(
      DirectoryReader.entries(atPath: tree.root.appendingPathComponent("missing").path) == nil)
    let file = try tree.file("f.bin", bytes: 1)
    #expect(DirectoryReader.entries(atPath: file.path) == nil)
  }

  @Test func dataVolumeIsAMountPoint() throws {
    // On macOS 10.15+ the data volume is mounted at /System/Volumes/Data.
    let entries = try #require(DirectoryReader.entries(atPath: "/System/Volumes"))
    let data = try #require(entries.first { $0.name == "Data" })
    #expect(data.isMountPoint)
  }
}
