import Foundation
import Testing

@testable import SpacerCore

private func child(_ node: FileNode?, _ name: String) -> FileNode? {
  node?.children.first { $0.name == name }
}

/// Removes what a test moved to the Trash, so runs do not fill the user's Trash.
private func discardTrashed(_ results: [DeletionResult]) {
  for case let url? in results.map(\.trashedURL) {
    try? FileManager.default.removeItem(at: url)
  }
}

/// Gives a scan's stray late results time to land. `cancel()` drops the tasks, so
/// `waitForScan()` cannot wait for them.
private func letLateScanResultsArrive() async throws {
  try await Task.sleep(for: .milliseconds(300))
}

@MainActor @Suite struct ScanSessionTests {
  /// a.bin (4 KB), docs/b.bin (8 KB), docs/deep/c.bin (12 KB).
  private func scannedSession() async throws -> (TempTree, ScanSession) {
    let tree = try TempTree()
    try tree.file("a.bin", bytes: 4096)
    try tree.file("docs/b.bin", bytes: 8192)
    try tree.file("docs/deep/c.bin", bytes: 12288)
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    return (tree, session)
  }

  @Test func scanMovesFromIdleThroughScanningToDone() async throws {
    let tree = try TempTree()
    try tree.file("x.bin", bytes: 4096)
    let session = ScanSession()
    guard case .idle = session.state else {
      Issue.record("expected idle")
      return
    }

    session.start(url: tree.root)
    #expect(session.isScanning)
    #expect(session.scanURL == tree.root)
    await session.waitForScan()

    guard case .done(let root) = session.state else {
      Issue.record("expected done")
      return
    }
    #expect(root === session.root)
    #expect(session.focus === root)
    #expect(root.size == (try tree.allocatedSize(tree.root.appendingPathComponent("x.bin"))))
    #expect(!session.rootAccessDenied)
    #expect(session.scanPreview == nil)
  }

  @Test func finishTimeIsSetByAScanAndKeptByOpeningIt() async throws {
    let tree = try TempTree()
    try tree.file("a.bin", bytes: 4096)
    try tree.file("other/b.bin", bytes: 4096)
    let session = ScanSession()
    #expect(session.finishedAt == nil)

    session.start(url: tree.root)
    #expect(session.finishedAt == nil)
    await session.waitForScan()
    let finished = try #require(session.finishedAt)

    session.open(url: tree.root)
    #expect(session.finishedAt == finished)

    session.start(url: tree.root.appendingPathComponent("other"))
    #expect(session.finishedAt == nil)
    await session.waitForScan()
    #expect(session.finishedAt != nil)
  }

  @Test(.enabled(if: getuid() != 0))
  func unreadableFoldersAreListedAfterAScanAndClearedByANewOne() async throws {
    let tree = try TempTree()
    try tree.file("open/ok.bin", bytes: 4096)
    try tree.file("locked/secret.bin", bytes: 4096)
    let locked = tree.root.appendingPathComponent("locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    let session = ScanSession()

    session.start(url: tree.root)
    #expect(session.unreadableFolders.count == 0)
    await session.waitForScan()

    #expect(session.unreadableFolders.count == 1)
    #expect(session.unreadableFolders.shown().first?.url.lastPathComponent == "locked")

    session.start(url: tree.root.appendingPathComponent("open"))
    #expect(session.unreadableFolders.count == 0)
    await session.waitForScan()
    #expect(session.unreadableFolders.count == 0)
  }

  @Test(.enabled(if: getuid() != 0))
  func fullDiskAccessProbeDecidesWhetherTheWarningSuggestsSettings() async throws {
    let tree = try TempTree()
    try tree.file("open/ok.bin", bytes: 4096)
    try tree.file("locked/secret.bin", bytes: 4096)
    let locked = tree.root.appendingPathComponent("locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

    let withoutAccess = ScanSession(fullDiskAccessProbe: { false })
    withoutAccess.start(url: tree.root)
    await withoutAccess.waitForScan()
    #expect(withoutAccess.unreadableFolders.count == 1)
    #expect(!withoutAccess.hasFullDiskAccess)
    #expect(withoutAccess.suggestsFullDiskAccess)

    let withAccess = ScanSession(fullDiskAccessProbe: { true })
    withAccess.start(url: tree.root)
    await withAccess.waitForScan()
    #expect(withAccess.unreadableFolders.count == 1)
    #expect(withAccess.hasFullDiskAccess)
    #expect(!withAccess.suggestsFullDiskAccess)
  }

  @Test func fullDiskAccessIsNotSuggestedWithoutUnreadableFolders() async throws {
    let tree = try TempTree()
    try tree.file("a.bin", bytes: 4096)
    let session = ScanSession(fullDiskAccessProbe: { false })
    session.start(url: tree.root)
    await session.waitForScan()
    #expect(session.unreadableFolders.count == 0)
    #expect(!session.hasFullDiskAccess)
    #expect(!session.suggestsFullDiskAccess)
  }

  @Test func scanPreviewIsClearedByCancelAndANewScan() async throws {
    let tree = try TempTree()
    for i in 0..<30 { try tree.file("d\(i)/f.bin", bytes: 10) }
    let session = ScanSession(scanner: DiskScanner(progressInterval: .zero, previewInterval: .zero))

    session.start(url: tree.root)
    #expect(session.scanPreview == nil)
    session.cancel()
    #expect(session.scanPreview == nil)
    await session.waitForScan()
    #expect(session.scanPreview == nil)
  }

  @Test func missingFolderFails() async throws {
    let tree = try TempTree()
    let session = ScanSession()
    session.start(url: tree.root.appendingPathComponent("missing"))
    await session.waitForScan()
    guard case .failed = session.state else {
      Issue.record("expected failed")
      return
    }
    #expect(session.root == nil)
  }

  @Test func cancelReturnsToIdle() async throws {
    let tree = try TempTree()
    for i in 0..<30 {
      try tree.file("d\(i)/f.bin", bytes: 10)
    }
    let session = ScanSession()
    session.start(url: tree.root)
    session.cancel()
    await session.waitForScan()
    guard case .idle = session.state else {
      Issue.record("expected idle")
      return
    }
    #expect(session.root == nil)
    session.cancel()  // no-op when not scanning
  }

  @Test func newScanReplacesARunningOne() async throws {
    let big = try TempTree()
    for i in 0..<50 { try big.file("d\(i)/f.bin", bytes: 10) }
    let small = try TempTree()
    try small.file("only.bin", bytes: 4096)
    defer { withExtendedLifetime((big, small)) {} }
    let session = ScanSession()

    session.start(url: big.root)
    session.start(url: small.root)
    await session.waitForScan()

    guard case .done(let root) = session.state else {
      Issue.record("expected done")
      return
    }
    #expect(root.url.lastPathComponent == small.root.lastPathComponent)
    #expect(root.children.map(\.name) == ["only.bin"])
  }

  @Test func failedScanDoesNotOverrideANewerOne() async throws {
    let tree = try TempTree()
    try tree.file("x.bin", bytes: 4096)
    let session = ScanSession()

    session.start(url: tree.root.appendingPathComponent("missing"))
    session.start(url: tree.root)
    await session.waitForScan()

    guard case .done = session.state else {
      Issue.record("expected done, got \(session.state)")
      return
    }
    #expect(session.root?.children.map(\.name) == ["x.bin"])
  }

  @Test func selectionTopmostSkipsNestedItems() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let docs = try #require(child(root, "docs"))
    let b = try #require(child(docs, "b.bin"))
    session.selection = [a, docs, b]

    #expect(session.selectionTopmost.map(\.name) == ["docs", "a.bin"])
    #expect(session.selectionSize == docs.size + a.size)
  }

  @Test func deleteLeavesTheTreeAloneWhenANewScanStarts() async throws {
    let tree = try TempTree()
    // Enough files that removing the folder takes a while off the main actor.
    for i in 0..<500 { try tree.file("many/f\(i).bin", bytes: 10) }
    try tree.file("keep.bin", bytes: 4096)
    defer { withExtendedLifetime(tree) {} }
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    let root = try #require(session.root)
    let many = try #require(child(root, "many"))
    let sizeBefore = root.size

    // The task signals before it calls `delete`, which sets `isDeleting` before it suspends, so
    // `isDeleting` is set by the time this test resumes. The removal then runs off the main actor.
    let (started, signal) = AsyncStream.makeStream(of: Void.self)
    let deletion = Task {
      signal.yield()
      return await session.delete([many], mode: .deletePermanently)
    }
    var startedSignals = started.makeAsyncIterator()
    _ = await startedSignals.next()
    try #require(session.isDeleting)
    #expect(await session.delete([many], mode: .deletePermanently).isEmpty)
    session.rescan()
    let finished = await deletion.value
    await session.waitForScan()

    #expect(finished.count == 1)
    #expect(root.size == sizeBefore)
    #expect(session.treeVersion == 0)
    #expect(!session.isDeleting)
    #expect(session.root !== root)
  }

  @Test func rescanBuildsAFreshTree() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let first = try #require(session.root)
    try tree.file("new.bin", bytes: 40_000)

    session.rescan()
    await session.waitForScan()

    let second = try #require(session.root)
    #expect(second !== first)
    #expect(second.size > first.size)
  }

  /// a.bin (4 KB), docs/b.bin (8 KB), other/o.bin (4 KB): two sibling folders to rescan apart.
  private func twoFolderSession() async throws -> (TempTree, ScanSession) {
    let tree = try TempTree()
    try tree.file("a.bin", bytes: 4096)
    try tree.file("docs/b.bin", bytes: 8192)
    try tree.file("other/o.bin", bytes: 4096)
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    return (tree, session)
  }

  @Test func zoomedRescanReplacesOnlyTheZoomedFolder() async throws {
    let (tree, session) = try await twoFolderSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    let other = try #require(child(root, "other"))
    let docsPath = docs.url.path
    let sizeBefore = root.size
    session.zoomIn(docs)
    #expect(session.rescansFocusOnly)
    try tree.file("docs/new.bin", bytes: 40_000)
    let newSize = try tree.allocatedSize(tree.root.appendingPathComponent("docs/new.bin"))
    let version = session.treeVersion
    let scannedAt = try #require(session.finishedAt)

    session.rescan()
    #expect(session.isScanning)
    #expect(session.retainedScan?.root === root)
    #expect(session.retainedScan?.focus === docs)
    await session.waitForScan()

    let fresh = try #require(session.focus)
    #expect(fresh !== docs)
    #expect(fresh.url.path == docsPath)
    #expect(fresh.name == "docs")
    #expect(child(fresh, "new.bin")?.size == newSize)
    #expect(child(fresh, "b.bin") != nil)
    #expect(session.root === root)
    #expect(child(root, "docs") === fresh)
    #expect(child(root, "other") === other)
    #expect(root.size == sizeBefore + newSize)
    #expect(session.treeVersion > version)
    #expect(try #require(session.finishedAt) > scannedAt)
    #expect(session.retainedScan == nil)
    #expect(docs.parent == nil)
    guard case .done(let shown) = session.state else {
      Issue.record("expected done, got \(session.state)")
      return
    }
    #expect(shown === root)
  }

  @Test func zoomedRescanDoesNotPickUpFilesInASibling() async throws {
    let (tree, session) = try await twoFolderSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    let other = try #require(child(root, "other"))
    session.zoomIn(docs)
    try tree.file("other/late.bin", bytes: 4096)

    session.rescan()
    await session.waitForScan()

    #expect(child(root, "other") === other)
    #expect(child(other, "late.bin") == nil)
    #expect(child(other, "o.bin") != nil)
  }

  @Test func rescanAtTheRootScansTheWholeLocation() async throws {
    let (tree, session) = try await twoFolderSession()
    defer { withExtendedLifetime(tree) {} }
    let first = try #require(session.root)
    session.zoomIn(try #require(child(first, "docs")))
    session.zoomTo(first)
    #expect(!session.rescansFocusOnly)

    session.rescan()
    await session.waitForScan()

    #expect(session.root !== first)
    #expect(session.focus === session.root)
    #expect(session.retainedScan == nil)
  }

  @Test func zoomedRescanDropsForwardHistoryInsideTheFolder() async throws {
    let tree = try TempTree()
    try tree.file("docs/deep/c.bin", bytes: 4096)
    try tree.file("docs/b.bin", bytes: 4096)
    defer { withExtendedLifetime(tree) {} }
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    let deep = try #require(child(docs, "deep"))
    session.zoomIn(docs)
    session.zoomIn(deep)
    session.goBack()
    #expect(session.focus === docs)
    #expect(session.canGoForward)

    session.rescan()
    await session.waitForScan()

    #expect(session.focus !== docs)
    #expect(session.focus?.parent === root)
    #expect(!session.canGoForward)
    session.goBack()
    #expect(session.focus === root)
  }

  @Test func zoomedRescanReplacesTheFolderInTheBackHistory() async throws {
    let tree = try TempTree()
    try tree.file("docs/deep/c.bin", bytes: 4096)
    try tree.file("docs/b.bin", bytes: 4096)
    defer { withExtendedLifetime(tree) {} }
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    let deep = try #require(child(docs, "deep"))
    session.zoomIn(docs)
    session.zoomIn(deep)
    session.zoomTo(docs)

    session.rescan()
    await session.waitForScan()

    let fresh = try #require(session.focus)
    #expect(fresh !== docs)
    session.goBack()
    #expect(session.focus === root)
    session.goForward()
    #expect(session.focus === fresh)
  }

  @Test func zoomedRescanOfAFolderThatIsGoneRestoresThePreviousMap() async throws {
    let (tree, session) = try await twoFolderSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    session.zoomIn(docs)
    let version = session.treeVersion
    try FileManager.default.removeItem(at: tree.root.appendingPathComponent("docs"))

    session.rescan()
    await session.waitForScan()

    #expect(session.root === root)
    #expect(session.focus === docs)
    #expect(child(root, "docs") === docs)
    #expect(session.retainedScan == nil)
    #expect(session.rescanFailure != nil)
    #expect(session.treeVersion == version)
    guard case .done(let shown) = session.state else {
      Issue.record("expected done, got \(session.state)")
      return
    }
    #expect(shown === root)
    session.dismissRescanFailure()
    #expect(session.rescanFailure == nil)
  }

  @Test func zoomedRescanOfAFolderThatIsNowAFileRestoresThePreviousMap() async throws {
    let (tree, session) = try await twoFolderSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    session.zoomIn(docs)
    let docsURL = tree.root.appendingPathComponent("docs")
    try FileManager.default.removeItem(at: docsURL)
    try tree.file("docs", bytes: 4096)

    session.rescan()
    await session.waitForScan()

    #expect(session.root === root)
    #expect(session.focus === docs)
    #expect(child(root, "docs") === docs)
    #expect(session.rescanFailure == "The folder is no longer a folder.")
  }

  @Test func cancelDuringZoomedRescanRestoresThePreviousTree() async throws {
    let (tree, session) = try await twoFolderSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    session.zoomIn(docs)
    try tree.file("docs/new.bin", bytes: 4096)

    session.rescan()
    session.cancel()

    #expect(session.retainedScan == nil)
    #expect(session.root === root)
    #expect(session.focus === docs)
    #expect(child(root, "docs") === docs)
    #expect(session.treeVersion == 0)
    try await letLateScanResultsArrive()
    #expect(session.root === root)
    #expect(session.focus === docs)
    #expect(!session.isScanning)
  }

  @Test(.enabled(if: getuid() != 0))
  func zoomedRescanListsAnUnreadableFolderInIt() async throws {
    let tree = try TempTree()
    try tree.file("docs/ok.bin", bytes: 4096)
    defer { withExtendedLifetime(tree) {} }
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    let docs = try #require(child(session.root, "docs"))
    session.zoomIn(docs)
    #expect(session.unreadableFolders.count == 0)

    try tree.file("docs/locked/secret.bin", bytes: 4096)
    let locked = tree.root.appendingPathComponent("docs/locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    session.rescan()
    await session.waitForScan()

    #expect(session.unreadableFolders.count == 1)
    #expect(session.unreadableFolders.shown().first?.url.lastPathComponent == "locked")
  }

  /// The files counted so far by the running scan, or nil when no scan is running.
  private func filesScanned(_ session: ScanSession) -> Int? {
    if case .scanning(let progress) = session.state { return progress.filesScanned }
    return nil
  }

  @Test func openSameURLAfterDoneKeepsTheTree() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let first = try #require(session.root)

    session.open(url: tree.root)

    #expect(session.root === first)
    #expect(session.focus === first)
    #expect(!session.isScanning)
    #expect(session.scanURL == tree.root)
  }

  @Test func openSameURLWhileScanningDoesNotRestart() async throws {
    let tree = try TempTree()
    // Enough files that the scan reports progress for a while.
    for i in 0..<500 { try tree.file("d\(i)/f.bin", bytes: 10) }
    defer { withExtendedLifetime(tree) {} }
    let session = ScanSession(scanner: DiskScanner(progressInterval: .zero, previewInterval: .zero))
    session.start(url: tree.root)
    // Wait for the first progress event, which ends early only if the scan finishes.
    while (filesScanned(session) ?? 0) == 0 && session.isScanning {
      try await Task.sleep(for: .milliseconds(1))
    }
    let before = try #require(filesScanned(session), "the scan finished before progress was seen")
    try #require(before > 0)

    session.open(url: tree.root)

    // A restart would reset the progress to zero at once.
    #expect(filesScanned(session) == before)
    await session.waitForScan()
    #expect(session.root?.children.count == 500)
  }

  @Test func openDifferentURLStartsANewScan() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let first = try #require(session.root)
    let other = try TempTree()
    try other.file("only.bin", bytes: 4096)
    defer { withExtendedLifetime(other) {} }

    session.open(url: other.root)
    #expect(session.isScanning)
    #expect(session.scanURL == other.root)
    await session.waitForScan()

    #expect(session.root !== first)
    #expect(session.root?.children.map(\.name) == ["only.bin"])
  }

  @Test func openURLDifferingOnlyByTrailingSlashOrDotsIsTheSameScan() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let first = try #require(session.root)

    session.open(url: URL(fileURLWithPath: tree.root.path + "/", isDirectory: true))
    #expect(session.root === first)
    #expect(!session.isScanning)

    session.open(url: tree.root.appendingPathComponent("docs/..", isDirectory: true))
    #expect(session.root === first)
    #expect(!session.isScanning)
  }

  @Test func openURLThroughASymlinkedPathIsTheSameScan() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let first = try #require(session.root)

    session.open(url: tree.root.resolvingSymlinksInPath())
    #expect(session.root === first)
    #expect(!session.isScanning)
  }

  @Test func openALinkRetargetedAfterTheScanStartsANewScan() async throws {
    let tree = try TempTree()
    try tree.file("one/a.bin", bytes: 4096)
    try tree.file("two/b.bin", bytes: 4096)
    defer { withExtendedLifetime(tree) {} }
    let link = tree.root.appendingPathComponent("link")
    let fm = FileManager.default
    try fm.createSymbolicLink(
      at: link, withDestinationURL: tree.root.appendingPathComponent("one", isDirectory: true))
    let session = ScanSession()
    session.start(url: link)
    await session.waitForScan()
    let first = try #require(session.root)
    session.open(url: link)
    #expect(session.root === first)

    try fm.removeItem(at: link)
    try fm.createSymbolicLink(
      at: link, withDestinationURL: tree.root.appendingPathComponent("two", isDirectory: true))
    session.open(url: link)

    #expect(session.isScanning)
    await session.waitForScan()
    #expect(session.root !== first)
    #expect(session.root?.children.map(\.name) == ["b.bin"])
  }

  @Test func openAfterAFailedScanRescans() async throws {
    let tree = try TempTree()
    defer { withExtendedLifetime(tree) {} }
    let missing = tree.root.appendingPathComponent("missing", isDirectory: true)
    let session = ScanSession()
    session.start(url: missing)
    await session.waitForScan()
    guard case .failed = session.state else {
      Issue.record("expected failed, got \(session.state)")
      return
    }

    session.open(url: missing)

    #expect(session.isScanning)
    await session.waitForScan()
    guard case .failed = session.state else {
      Issue.record("expected failed again, got \(session.state)")
      return
    }
  }

  @Test func openAfterACancelledScanStartsIt() async throws {
    let tree = try TempTree()
    try tree.file("x.bin", bytes: 4096)
    defer { withExtendedLifetime(tree) {} }
    let session = ScanSession()
    session.start(url: tree.root)
    session.cancel()

    session.open(url: tree.root)

    #expect(session.isScanning)
    await session.waitForScan()
    #expect(session.root?.children.map(\.name) == ["x.bin"])
  }

  @Test func openResetsFocusAndHistoryToTheRoot() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    let deep = try #require(child(docs, "deep"))
    session.zoomIn(docs)
    session.zoomIn(deep)
    #expect(session.focus === deep)
    #expect(session.canGoBack)

    session.open(url: tree.root)

    #expect(session.focus === root)
    #expect(session.breadcrumbs.count == 1)
    #expect(!session.canZoomOut)
    #expect(!session.canGoBack)
  }

  @Test func rescanAlwaysRescansTheSameURL() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let first = try #require(session.root)
    // Read before the rescan: the replaced tree is taken apart afterwards.
    let names = first.children.map(\.name).sorted()

    session.rescan()
    #expect(session.isScanning)
    await session.waitForScan()

    #expect(session.root !== first)
    #expect(session.root?.children.map(\.name).sorted() == names)
  }

  @Test func zoomInOutAndBreadcrumbs() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    let deep = try #require(child(docs, "deep"))
    let c = try #require(child(deep, "c.bin"))

    #expect(!session.canZoomOut)
    session.zoomIn(deep)
    #expect(session.focus === deep)
    #expect(session.breadcrumbs.map(\.name) == [root.name, "docs", "deep"])
    #expect(session.canZoomOut)

    session.zoomOut()
    #expect(session.focus === docs)
    session.zoomTo(root)
    #expect(session.focus === root)
    session.zoomOut()
    #expect(session.focus === root)

    session.zoomIn(c)
    #expect(session.focus === deep)

    let stranger = FileNode(name: "x", url: URL(fileURLWithPath: "/x"), children: [])
    session.zoomIn(stranger)
    session.zoomTo(stranger)
    #expect(session.focus === deep)
  }

  @Test func goBackRetracesZooms() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    let deep = try #require(child(docs, "deep"))

    #expect(!session.canGoBack)
    session.zoomIn(deep)
    session.zoomTo(root)
    session.zoomIn(docs)
    session.zoomIn(docs)  // already there: not recorded
    #expect(session.canGoBack)

    session.goBack()
    #expect(session.focus === root)
    session.goBack()
    #expect(session.focus === deep)
    session.goBack()
    #expect(session.focus === root)
    #expect(!session.canGoBack)
    session.goBack()  // no-op with an empty history
    #expect(session.focus === root)
  }

  @Test func goBackSkipsDeletedFolders() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    let deep = try #require(child(docs, "deep"))

    session.zoomIn(deep)
    session.zoomOut()
    let results = await session.delete([deep], mode: .moveToTrash)
    defer { discardTrashed(results) }

    #expect(session.focus === docs)
    session.goBack()
    #expect(session.focus === root)
    #expect(!session.canGoBack)
  }

  @Test func newScanClearsHistory() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    session.zoomIn(try #require(child(root, "docs")))
    session.zoomTo(root)
    #expect(session.canGoBack)

    session.rescan()
    await session.waitForScan()
    #expect(!session.canGoBack)
  }

  @Test func sameLocationRescanKeepsThePreviousTreeUntilItFinishes() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let first = try #require(session.root)

    // Memory: the old tree is held only by `retainedScan` until the new scan finishes, and
    // nothing else (the scanner, the preview, the views) keeps a reference to it.
    session.rescan()

    #expect(session.isScanning)
    #expect(session.retainedScan?.root === first)
    await session.waitForScan()
    #expect(session.retainedScan == nil)
    #expect(session.root !== first)
  }

  @Test func cancelDuringSameLocationRescanRestoresThePreviousScan() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let first = try #require(session.root)
    let docs = try #require(child(first, "docs"))
    session.zoomIn(docs)
    let finished = try #require(session.finishedAt)

    session.rescan()
    session.cancel()

    #expect(session.retainedScan == nil)
    #expect(session.root === first)
    #expect(session.focus === docs)
    #expect(session.canGoBack)
    #expect(session.finishedAt == finished)
    guard case .done(let shown) = session.state else {
      Issue.record("expected done, got \(session.state)")
      return
    }
    #expect(shown === first)
    try await letLateScanResultsArrive()
    #expect(session.root === first)
    #expect(!session.isScanning)
  }

  @Test func cancelDuringAnotherLocationScanGoesIdle() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let other = try TempTree()
    try other.file("only.bin", bytes: 4096)
    defer { withExtendedLifetime(other) {} }

    session.start(url: other.root)
    #expect(session.retainedScan == nil)
    session.cancel()

    #expect(session.retainedScan == nil)
    #expect(session.root == nil)
    #expect(session.focus == nil)
    guard case .idle = session.state else {
      Issue.record("expected idle, got \(session.state)")
      return
    }
    try await letLateScanResultsArrive()
    #expect(session.root == nil)
    guard case .idle = session.state else {
      Issue.record("expected idle after the late result, got \(session.state)")
      return
    }
  }

  @Test func goForwardRetracesGoBackAndNewZoomClearsIt() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    let deep = try #require(child(docs, "deep"))
    session.zoomIn(docs)
    session.zoomIn(deep)

    #expect(!session.canGoForward)
    session.goBack()
    #expect(session.focus === docs)
    #expect(session.canGoForward)
    session.goForward()
    #expect(session.focus === deep)
    #expect(!session.canGoForward)

    session.goBack()
    session.zoomTo(root)
    #expect(session.focus === root)
    #expect(!session.canGoForward)
    session.goForward()  // no-op with an empty forward history
    #expect(session.focus === root)
  }

  @Test func goForwardSkipsDeletedFoldersAndOpenClearsHistory() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let docs = try #require(child(root, "docs"))
    let deep = try #require(child(docs, "deep"))
    session.zoomIn(deep)
    session.goBack()
    #expect(session.focus === root)
    #expect(session.canGoForward)

    await session.delete([deep], mode: .deletePermanently)

    #expect(!session.canGoForward)
    session.goForward()
    #expect(session.focus === root)

    session.zoomIn(docs)
    session.goBack()
    #expect(session.canGoForward)
    session.open(url: tree.root)
    #expect(session.focus === root)
    #expect(!session.canGoForward)
  }

  @Test func selectionReplacesOrExtends() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let docs = try #require(child(root, "docs"))

    session.select(a)
    session.select(docs, extending: true)
    #expect(session.selection == [a, docs])
    #expect(session.selectionSize == a.size + docs.size)
    session.select(a, extending: true)
    #expect(session.selection == [docs])
    session.select(a)
    #expect(session.selection == [a])
  }

  @Test func deletingSelectionUpdatesTreeAndClearsSelection() async throws {
    let (tree, session) = try await scannedSession()
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let docs = try #require(child(root, "docs"))
    let deep = try #require(child(docs, "deep"))
    let c = try #require(child(deep, "c.bin"))
    let sizeBefore = root.size
    let removedSize = a.size + deep.size
    session.zoomIn(deep)
    session.hovered = c
    session.selection = [a, deep, c]

    let results = await session.delete(session.selection, mode: .deletePermanently)

    #expect(results.count == 3)
    #expect(results.allSatisfy { $0.succeeded })
    #expect(root.size == sizeBefore - removedSize)
    #expect(docs.children.map(\.name) == ["b.bin"])
    #expect(session.selection.isEmpty)
    #expect(session.focus === docs)
    #expect(session.hovered == nil)
    #expect(session.treeVersion == 1)
    #expect(!session.isDeleting)
    #expect(!FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("a.bin").path))
  }

  @Test func deleteKeepsCategoryStatsRight() async throws {
    let tree = try TempTree()
    defer { withExtendedLifetime(tree) {} }
    try tree.file("movie.mov", bytes: 40960)
    try tree.file("songs/a.mp3", bytes: 16384)
    try tree.file("songs/b.mp3", bytes: 16384)
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    let root = try #require(session.root)
    let movie = try #require(child(root, "movie.mov"))
    #expect(root.categoryStats.total == root.size)
    #expect(root.dominantCategory == .video)

    await session.delete([movie], mode: .deletePermanently)

    #expect(session.treeVersion == 1)
    #expect(root.categoryStats[.video] == 0)
    #expect(root.categoryStats.total == root.size)
    #expect(root.dominantCategory == .audio)
  }

  @Test func refusedItemsStayInTheTree() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let sizeBefore = root.size
    session.selection = [root, a]

    let results = await session.delete(session.selection, mode: .deletePermanently)

    #expect(results.first { $0.node === root }?.error == .scanRoot)
    #expect(results.first { $0.node === a }?.succeeded == true)
    #expect(session.selection == [root])
    #expect(root.size == sizeBefore - a.size)
  }

  @Test func movedToTrashItemsCanBeUndone() async throws {
    let (tree, session) = try await scannedSession()
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let docs = try #require(child(root, "docs"))
    let sizeBefore = root.size
    let summary = "Moved 2 items to Trash · \(ByteFormat.string(a.size + docs.size))"
    session.selection = [a, docs]

    let results = await session.delete(session.selection, mode: .moveToTrash)
    defer { discardTrashed(results) }

    #expect(results.allSatisfy { $0.succeeded })
    #expect(session.undoableTrash?.items.count == 2)
    #expect(session.undoableTrash?.summaryText == summary)
    #expect(root.size == sizeBefore - a.size - docs.size)

    let undo = await session.undoLastTrash()

    #expect(undo.count == 2)
    #expect(undo.allSatisfy { $0.succeeded })
    #expect(root.size == sizeBefore)
    #expect(root.categoryStats.total == root.size)
    #expect(child(root, "a.bin") === a)
    #expect(child(root, "docs") === docs)
    #expect(session.treeVersion == 2)
    #expect(session.undoableTrash == nil)
    #expect(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("a.bin").path))
    #expect(
      FileManager.default.fileExists(
        atPath: tree.root.appendingPathComponent("docs/deep/c.bin").path))
  }

  @Test func singleTrashedItemHasANamedSummary() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))

    let results = await session.delete([a], mode: .moveToTrash)
    defer { discardTrashed(results) }

    #expect(
      session.undoableTrash?.summaryText == "Moved “a.bin” to Trash · \(ByteFormat.string(a.size))")
  }

  @Test func permanentDeleteLeavesNothingToUndo() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let docs = try #require(child(root, "docs"))
    let trashed = await session.delete([a], mode: .moveToTrash)
    defer { discardTrashed(trashed) }
    #expect(session.undoableTrash != nil)

    let permanent = await session.delete([docs], mode: .deletePermanently)

    #expect(permanent.allSatisfy { $0.succeeded })
    #expect(session.undoableTrash == nil)
    #expect(await session.undoLastTrash().isEmpty)
  }

  @Test func dismissUndoKeepsTheItemsInTheTrash() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let results = await session.delete([a], mode: .moveToTrash)
    let trashed = try #require(results.first?.trashedURL)
    defer { try? FileManager.default.removeItem(at: trashed) }

    session.dismissUndo()

    #expect(session.undoableTrash == nil)
    #expect(await session.undoLastTrash().isEmpty)
    #expect(FileManager.default.fileExists(atPath: trashed.path))
  }

  @Test func newScanClearsTheUndo() async throws {
    let (tree, session) = try await scannedSession()
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let results = await session.delete([a], mode: .moveToTrash)
    defer { discardTrashed(results) }
    #expect(session.undoableTrash != nil)

    session.start(url: tree.root)
    await session.waitForScan()

    #expect(session.undoableTrash == nil)
  }

  @Test func deletedSummaryCountsOnlyTopmostItems() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let docs = try #require(child(root, "docs"))
    let b = try #require(child(docs, "b.bin"))
    let deleted = DeletionResult(node: docs, error: nil, trashedURL: nil)
    let inside = DeletionResult(node: b, error: nil, trashedURL: nil)
    let refused = DeletionResult(node: a, error: .scanRoot, trashedURL: nil)

    #expect(
      DeletionSummary.deleted(results: [deleted, inside, refused])
        == "Deleted “docs” · \(ByteFormat.string(docs.size))")
    #expect(
      DeletionSummary.deleted(results: [
        inside, DeletionResult(node: a, error: nil, trashedURL: nil),
      ])
        == "Deleted 2 items · \(ByteFormat.string(a.size + b.size))")
    #expect(DeletionSummary.deleted(results: [refused]) == nil)
  }

  @Test func failedSameLocationRescanKeepsThePreviousScan() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let first = try #require(session.root)
    let finished = try #require(session.finishedAt)
    #expect(session.rescanFailure == nil)
    try FileManager.default.removeItem(at: tree.root)

    session.rescan()
    await session.waitForScan()

    #expect(session.root === first)
    #expect(session.retainedScan == nil)
    #expect(session.finishedAt == finished)
    #expect(session.rescanFailure != nil)
    guard case .done(let shown) = session.state else {
      Issue.record("expected done, got \(session.state)")
      return
    }
    #expect(shown === first)

    session.dismissRescanFailure()
    #expect(session.rescanFailure == nil)
  }

  @Test func failedScanOfAnotherLocationStillFails() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }

    session.start(url: tree.root.appendingPathComponent("missing"))
    await session.waitForScan()

    guard case .failed = session.state else {
      Issue.record("expected failed, got \(session.state)")
      return
    }
    #expect(session.root == nil)
    #expect(session.rescanFailure == nil)
  }

  @Test func rescanWhileDeletingKeepsNoRetainedScan() async throws {
    let tree = try TempTree()
    for i in 0..<500 { try tree.file("many/f\(i).bin", bytes: 10) }
    try tree.file("keep.bin", bytes: 4096)
    defer { withExtendedLifetime(tree) {} }
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    let root = try #require(session.root)
    let many = try #require(child(root, "many"))

    let (started, signal) = AsyncStream.makeStream(of: Void.self)
    let deletion = Task {
      signal.yield()
      return await session.delete([many], mode: .deletePermanently)
    }
    var startedSignals = started.makeAsyncIterator()
    _ = await startedSignals.next()
    try #require(session.isDeleting)
    session.rescan()

    // The old tree would still list the deleted folder, so it must not become the map to go back to.
    #expect(session.retainedScan == nil)
    session.cancel()
    #expect(session.root == nil)
    _ = await deletion.value
    #expect(!session.isDeleting)
  }

  @Test(.enabled(if: getuid() != 0))
  func deleteAndUndoKeepTheUnreadableListInStep() async throws {
    let tree = try TempTree()
    try tree.file("outer/locked/secret.bin", bytes: 4096)
    try tree.file("keep.bin", bytes: 4096)
    defer { withExtendedLifetime(tree) {} }
    let locked = tree.root.appendingPathComponent("outer/locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    let root = try #require(session.root)
    let outer = try #require(child(root, "outer"))
    #expect(session.unreadableFolders.count == 1)

    let results = await session.delete([outer], mode: .moveToTrash)
    defer {
      for case let url? in results.map(\.trashedURL) {
        let inTrash = url.appendingPathComponent("locked")
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: inTrash.path)
        try? FileManager.default.removeItem(at: url)
      }
    }
    #expect(session.unreadableFolders.count == 0)

    let undo = await session.undoLastTrash()
    #expect(undo.allSatisfy { $0.succeeded })
    #expect(session.unreadableFolders.count == 1)
    #expect(session.unreadableFolders.nodes.allSatisfy { root.contains($0) })
  }

  @Test func undoReportsAnItemWhosePathIsTakenAndRestoresTheOthers() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let docs = try #require(child(root, "docs"))
    let sizeBefore = root.size
    let results = await session.delete([a, docs], mode: .moveToTrash)
    defer { discardTrashed(results) }
    try tree.file("a.bin", bytes: 10)

    let undo = await session.undoLastTrash()

    #expect(undo.count == 2)
    #expect(undo.first { $0.node === a }?.succeeded == false)
    #expect(undo.first { $0.node === docs }?.succeeded == true)
    #expect(a.parent == nil)
    #expect(child(root, "docs") === docs)
    #expect(root.size == sizeBefore - a.size)
    #expect(root.categoryStats.total == root.size)
    #expect(session.treeVersion == 2)
    #expect(session.undoableTrash == nil)
  }

  @Test func undoThatRestoresNothingDoesNotBumpTheTreeVersion() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let results = await session.delete([a], mode: .moveToTrash)
    defer { discardTrashed(results) }
    try tree.file("a.bin", bytes: 10)

    let undo = await session.undoLastTrash()

    #expect(undo.count == 1)
    #expect(!undo[0].succeeded)
    #expect(a.parent == nil)
    #expect(session.treeVersion == 1)
    // The item stays in the Trash; the undo is spent either way.
    #expect(session.undoableTrash == nil)
  }

  @Test func undoLeavesTheNewTreeAloneWhenANewScanStarts() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let results = await session.delete([a], mode: .moveToTrash)
    defer { discardTrashed(results) }
    #expect(session.treeVersion == 1)

    // The task signals before it calls `undoLastTrash`, which sets `isDeleting` before it
    // suspends, so the new scan starts while the undo is suspended.
    let (started, signal) = AsyncStream.makeStream(of: Void.self)
    let undoing = Task {
      signal.yield()
      return await session.undoLastTrash()
    }
    var startedSignals = started.makeAsyncIterator()
    _ = await startedSignals.next()
    try #require(session.isDeleting)
    session.rescan()
    let undo = await undoing.value
    await session.waitForScan()

    #expect(undo.count == 1)
    #expect(a.parent == nil)
    #expect(session.root !== root)
    #expect(session.treeVersion == 1)
    #expect(session.undoableTrash == nil)
    guard case .done = session.state else {
      Issue.record("expected the new scan to be done, got \(session.state)")
      return
    }
  }

  @Test func trashedSummaryNamesTheItemsMovedToTheTrash() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    let docs = try #require(child(root, "docs"))
    let one = DeletionResult(node: a, error: nil, trashedURL: nil)
    let two = DeletionResult(node: docs, error: nil, trashedURL: nil)
    let refused = DeletionResult(node: root, error: .scanRoot, trashedURL: nil)

    #expect(
      DeletionSummary.trashed(results: [one, refused])
        == "Moved “a.bin” to Trash · \(ByteFormat.string(a.size))")
    #expect(
      DeletionSummary.trashed(results: [one, two])
        == "Moved 2 items to Trash · \(ByteFormat.string(a.size + docs.size))")
    #expect(DeletionSummary.trashed(results: [refused]) == nil)
  }

  @Test func unreadableFoldersCanDropAndAddNodes() {
    func denied(_ name: String) -> FileNode {
      FileNode(
        name: name, url: URL(fileURLWithPath: "/t/\(name)", isDirectory: true), children: [],
        accessDenied: true)
    }
    let b = denied("b")
    let a = denied("a")
    let inner = denied("c")
    let holder = FileNode(
      name: "holder", url: URL(fileURLWithPath: "/t/holder", isDirectory: true), children: [inner])
    let all = UnreadableFolders([b, inner, a])
    #expect(all.nodes.map(\.name) == ["a", "b", "c"])

    let withoutHolder = all.removing(under: [holder])
    #expect(withoutHolder.nodes.map(\.name) == ["a", "b"])
    #expect(all.removing(under: []).count == 3)
    #expect(withoutHolder.adding([inner]).nodes.map(\.name) == ["a", "b", "c"])
    #expect(withoutHolder.adding([]).count == 2)
  }

  @Test func smallItemsGroupIsClearedBySelectAndStart() async throws {
    let (tree, session) = try await scannedSession()
    defer { withExtendedLifetime(tree) {} }
    let root = try #require(session.root)
    let a = try #require(child(root, "a.bin"))
    session.smallItemsGroup = SmallItemsGroup(parent: root, count: 2, size: 12)
    session.select(a)
    #expect(session.smallItemsGroup == nil)

    session.smallItemsGroup = SmallItemsGroup(parent: root, count: 2, size: 12)
    session.start(url: tree.root)
    #expect(session.smallItemsGroup == nil)
    await session.waitForScan()
  }

  @Test func deleteWithoutScanDoesNothing() async {
    let session = ScanSession()
    let node = FileNode(name: "x", url: URL(fileURLWithPath: "/tmp/x"), size: 1)
    #expect(await session.delete([node], mode: .moveToTrash).isEmpty)
  }

  @Test func volumeCapacityFraction() {
    let volume = VolumeInfo(
      url: URL(fileURLWithPath: "/"), name: "Disk", totalCapacity: 1000, availableCapacity: 250)
    #expect(volume.usedCapacity == 750)
    #expect(volume.usedFraction == 0.75)
    let unknown = VolumeInfo(
      url: URL(fileURLWithPath: "/"), name: "?", totalCapacity: 0, availableCapacity: 0)
    #expect(unknown.usedFraction == 0)
  }

  @Test func mountedVolumesIncludeTheStartupDisk() {
    let volumes = VolumeInfo.mounted()
    let startup = volumes.first { $0.url.path == "/" }
    #expect(startup != nil)
    #expect((startup?.totalCapacity ?? 0) > 0)
    #expect((startup?.availableCapacity ?? 0) > 0)
  }
}
