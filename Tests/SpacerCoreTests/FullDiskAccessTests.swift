import Foundation
import Testing

@testable import SpacerCore

@Suite struct FullDiskAccessTests {
  @Test func readableFileMeansAccessIsGranted() throws {
    let tree = try TempTree()
    let file = try tree.file("ok.bin", bytes: 10)
    #expect(FullDiskAccess.isGranted(probePaths: [file.path]))
  }

  @Test func missingPathIsSkippedForTheNextOne() throws {
    let tree = try TempTree()
    let file = try tree.file("ok.bin", bytes: 10)
    let missing = tree.root.appendingPathComponent("missing.bin").path
    #expect(FullDiskAccess.isGranted(probePaths: [missing, file.path]))
  }

  @Test func onlyMissingPathsMeansAccessIsNotProven() throws {
    let tree = try TempTree()
    let missing = tree.root.appendingPathComponent("missing.bin").path
    #expect(!FullDiskAccess.isGranted(probePaths: [missing]))
    #expect(!FullDiskAccess.isGranted(probePaths: []))
  }

  @Test(.enabled(if: getuid() != 0))
  func refusedFileMeansAccessIsNotGranted() throws {
    let tree = try TempTree()
    let locked = try tree.file("locked.bin", bytes: 10)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    #expect(!FullDiskAccess.isGranted(probePaths: [locked.path]))
  }

  @Test(.enabled(if: getuid() != 0))
  func aRefusedPathDecidesBeforeAReadableOne() throws {
    let tree = try TempTree()
    let locked = try tree.file("locked.bin", bytes: 10)
    let open = try tree.file("open.bin", bytes: 10)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    #expect(!FullDiskAccess.isGranted(probePaths: [locked.path, open.path]))
  }

  @Test func defaultProbePathsAreTheTCCDatabaseThenTheHomeSafariBookmarks() {
    let paths = FullDiskAccess.defaultProbePaths
    #expect(paths.count == 2)
    #expect(paths.first == "/Library/Application Support/com.apple.TCC/TCC.db")
    #expect(
      paths.last
        == FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Safari/Bookmarks.plist").path)
  }
}
