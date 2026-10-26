import Foundation
import Testing

@testable import SpacerCore

private func makeTree() -> FileNode {
  let url = URL(fileURLWithPath: "/scan")
  let files = (1...12).map { index in
    FileNode(
      name: "file\(index).bin", url: url.appendingPathComponent("file\(index).bin"),
      size: Int64(index * 100))
  }
  let photos = FileNode(
    name: "Photos", url: url.appendingPathComponent("Photos"),
    children: [
      FileNode(name: "Café.JPG", url: url.appendingPathComponent("Photos/Café.JPG"), size: 50)
    ])
  return FileNode(name: "scan", url: url, children: files + [photos])
}

@Suite struct ViewHelperTests {
  @Test func largestChildrenAreTheFirstTenBySize() {
    let root = makeTree()
    let largest = root.largestChildren()
    #expect(largest.count == 10)
    #expect(largest.first?.name == "file12.bin")
    #expect(largest.map(\.size) == largest.map(\.size).sorted(by: >))
    #expect(root.largestChildren(0).isEmpty)
    #expect(root.largestChildren(-3).isEmpty)
    #expect(root.largestChildren(100).count == root.children.count)
  }

  @Test func nameMatchesIgnoringCaseAccentsAndSpaces() {
    let root = makeTree()
    let nodes = [root] + root.children + root.children.flatMap(\.children)
    #expect(nodes.filter { $0.nameMatches("cafe.jpg") }.map(\.name) == ["Café.JPG"])
    #expect(nodes.filter { $0.nameMatches("  photos ") }.map(\.name) == ["Photos"])
    #expect(nodes.filter { $0.nameMatches("FILE1") }.count == 4)  // file1, file10, file11, file12
    #expect(root.nameMatches(" SCAN "))
    #expect(!root.nameMatches(""))
    #expect(!root.nameMatches("   "))
    #expect(!root.nameMatches("nothing"))
  }

  @Test func capacityTextShowsUsedFreeAndTotal() {
    let volume = VolumeInfo(
      url: URL(fileURLWithPath: "/"), name: "Disk", totalCapacity: 500_000_000_000,
      availableCapacity: 120_000_000_000)
    #expect(volume.usedCapacity == 380_000_000_000)
  }

  @Test func usedAndFreeTextForTheSidebar() {
    let volume = VolumeInfo(
      url: URL(fileURLWithPath: "/"), name: "Disk", totalCapacity: 500_000_000_000,
      availableCapacity: 120_000_000_000)
    #expect(volume.usedAndFreeText == "380 GB used · 120 GB free")
  }

  @Test func usedCapacityClampsAtZeroWhenAvailableExceedsTotal() {
    let volume = VolumeInfo(
      url: URL(fileURLWithPath: "/"), name: "Disk", totalCapacity: 100, availableCapacity: 150)
    #expect(volume.usedCapacity == 0)
    #expect(volume.usedFraction == 0)
  }

  @Test func deletionErrorsHaveMessages() {
    let errors: [DeletionError] = [
      .scanRoot, .volumeRoot, .homeFolder, .systemPath, .systemApp, .outsideScanRoot,
    ]
    #expect(Set(errors.map(\.message)).count == errors.count)
    #expect(errors.allSatisfy { !$0.message.isEmpty })
    #expect(DeletionError.failed("Disk is locked").message == "Disk is locked")
  }

  @Test func fullDiskAccessURLOpensPrivacySettings() {
    #expect(FullDiskAccess.settingsURL.scheme == "x-apple.systempreferences")
    #expect(FullDiskAccess.settingsURL.absoluteString.hasSuffix("Privacy_AllFiles"))
  }

  @Test func itemDetailsReadKindAndDate() throws {
    let tree = try TempTree()
    let url = try tree.file("notes.txt", bytes: 10)
    let details = ItemDetails.load(for: FileNode(name: "notes.txt", url: url, size: 10))
    #expect(!details.kind.isEmpty)
    #expect(details.modified != nil)

    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(
      ItemDetails.load(for: FileNode(name: "x", url: missing, children: []))
        == ItemDetails(kind: "Folder", modified: nil))
    #expect(ItemDetails.load(for: FileNode(name: "x", url: missing, size: 0)).kind == "File")
  }
}

@Suite final class RecentScansTests {
  private let suiteName = "SpacerTests-\(UUID().uuidString)"

  deinit {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }

  private func makeDefaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test func newestFirstWithoutDuplicates() {
    let recents = RecentScans(defaults: makeDefaults())
    #expect(recents.urls.isEmpty)
    recents.add(URL(fileURLWithPath: "/a"))
    recents.add(URL(fileURLWithPath: "/b"))
    let list = recents.add(URL(fileURLWithPath: "/a/"))
    #expect(list.map(\.path) == ["/a", "/b"])
    #expect(recents.urls.map(\.path) == ["/a", "/b"])
  }

  @Test func keepsOnlyTheLimit() {
    let recents = RecentScans(defaults: makeDefaults(), limit: 3)
    for name in ["a", "b", "c", "d"] { recents.add(URL(fileURLWithPath: "/\(name)")) }
    #expect(recents.urls.map(\.path) == ["/d", "/c", "/b"])
    recents.clear()
    #expect(recents.urls.isEmpty)
  }
}
