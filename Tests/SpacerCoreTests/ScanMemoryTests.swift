import Foundation
import Testing

@testable import SpacerCore

/// A scan's tree must be freed once nothing shows it any more: rescans and new scans must not
/// keep old trees alive.
@MainActor @Suite struct ScanMemoryTests {
  private func tree() throws -> TempTree {
    let tree = try TempTree()
    try tree.file("a.bin", bytes: 4096)
    try tree.file("docs/b.bin", bytes: 8192)
    try tree.file("docs/deep/c.bin", bytes: 12288)
    return tree
  }

  /// Lets tasks that still hold the old tree finish.
  private func settle() async throws {
    try await Task.sleep(for: .milliseconds(300))
  }

  @Test func rescanFreesThePreviousTree() async throws {
    let tree = try tree()
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    weak var oldRoot = session.root
    weak var oldLeaf = session.root?.children.first
    #expect(oldRoot != nil)

    session.rescan()
    await session.waitForScan()
    try await settle()

    #expect(session.root != nil)
    #expect(oldRoot == nil)
    #expect(oldLeaf == nil)
  }

  @Test func repeatedRescansKeepOnlyTheCurrentTree() async throws {
    let tree = try tree()
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    var old: [() -> FileNode?] = []
    for _ in 0..<3 {
      weak var root = session.root
      old.append { root }
      session.rescan()
      await session.waitForScan()
    }
    try await settle()
    #expect(old.allSatisfy { $0() == nil })
  }

  @Test func scanningAnotherLocationFreesThePreviousTree() async throws {
    let first = try tree()
    let second = try tree()
    let session = ScanSession()
    session.start(url: first.root)
    await session.waitForScan()
    weak var oldRoot = session.root

    session.open(url: second.root)
    await session.waitForScan()
    try await settle()

    #expect(oldRoot == nil)
  }

  @Test func zoomedRescanFreesTheReplacedFolder() async throws {
    let tree = try tree()
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    session.zoomTo(try #require(session.root?.children.first { $0.name == "docs" }))
    weak var oldDocs = session.focus

    session.rescan()
    await session.waitForScan()
    try await settle()

    #expect(session.focus?.name == "docs")
    #expect(oldDocs == nil)
  }

  /// With progress and previews on every update, as in a long scan in the app.
  @Test func rescanWithPreviewsFreesThePreviousTree() async throws {
    let tree = try TempTree()
    for folder in 0..<20 {
      for file in 0..<20 {
        try tree.file("f\(folder)/sub/x\(file).bin", bytes: 4096)
      }
    }
    let session = ScanSession(
      scanner: DiskScanner(maxConcurrency: 4, progressInterval: .zero, previewInterval: .zero))
    session.start(url: tree.root)
    await session.waitForScan()
    weak var oldRoot = session.root
    weak var oldFolder = session.root?.children.first

    session.rescan()
    await session.waitForScan()
    session.rescan()
    await session.waitForScan()
    try await settle()

    #expect(oldRoot == nil)
    #expect(oldFolder == nil)
  }

  // A view that is gone can still hold a node, as SwiftUI's stale key press handlers and button
  // actions do. Holding the old root must not keep the old tree.

  @Test func heldOldRootIsEmptiedAfterRescan() async throws {
    let tree = try tree()
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    let held = try #require(session.root)
    weak var oldFolder = held.children.first { $0.isDirectory }
    #expect(oldFolder != nil)

    session.rescan()
    await session.waitForScan()
    try await settle()

    #expect(held.children.isEmpty)
    #expect(oldFolder == nil)
    #expect(session.root !== held)
    #expect(session.root?.children.isEmpty == false)
  }

  @Test func heldOldRootIsEmptiedAfterScanningAnotherLocation() async throws {
    let first = try tree()
    let second = try tree()
    let session = ScanSession()
    session.start(url: first.root)
    await session.waitForScan()
    let held = try #require(session.root)

    session.open(url: second.root)
    await session.waitForScan()
    try await settle()

    #expect(held.children.isEmpty)
    #expect(session.root?.children.isEmpty == false)
  }

  @Test func heldReplacedFolderIsEmptiedAfterZoomedRescan() async throws {
    let tree = try tree()
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    let held = try #require(session.root?.children.first { $0.name == "docs" })
    session.zoomTo(held)

    session.rescan()
    await session.waitForScan()
    try await settle()

    #expect(held.children.isEmpty)
    let fresh = try #require(session.focus)
    #expect(fresh !== held)
    #expect(fresh.name == "docs")
    #expect(!fresh.children.isEmpty)
    #expect(session.root?.children.contains { $0 === fresh } == true)
  }

  @Test func stoppedRescanKeepsTheShownTreeIntact() async throws {
    let tree = try tree()
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    let shown = try #require(session.root)
    let count = shown.itemCount

    session.rescan()
    session.cancel()
    try await settle()

    #expect(session.root === shown)
    #expect(!shown.children.isEmpty)
    #expect(shown.itemCount == count)
  }
}
