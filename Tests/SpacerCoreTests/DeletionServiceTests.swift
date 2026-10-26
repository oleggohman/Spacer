import Foundation
import Testing

@testable import SpacerCore

private func child(_ node: FileNode, _ name: String) -> FileNode? {
  node.children.first { $0.name == name }
}

private func exists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}

@Suite struct DeletionServiceTests {
  /// Scans a temp tree with a.bin (4 KB), docs/b.bin (8 KB) and docs/c.bin (12 KB).
  private func scannedTree() async throws -> (TempTree, FileNode) {
    let tree = try TempTree()
    try tree.file("a.bin", bytes: 4096)
    try tree.file("docs/b.bin", bytes: 8192)
    try tree.file("docs/c.bin", bytes: 12288)
    let root = try await DiskScanner().scan(tree.root)
    return (tree, root)
  }

  @Test func movesFileAndFolderToTrash() async throws {
    let (tree, root) = try await scannedTree()
    let file = try #require(child(root, "a.bin"))
    let folder = try #require(child(root, "docs"))
    let results = await DeletionService(root: tree.root).delete(
      nodes: [file, folder], mode: .moveToTrash)
    defer {
      for case let url? in results.map(\.trashedURL) {
        try? FileManager.default.removeItem(at: url)
      }
    }

    #expect(results.allSatisfy { $0.succeeded })
    #expect(results.allSatisfy { $0.trashedURL != nil })
    #expect(!exists(file.url))
    #expect(!exists(folder.url))
    for case let url? in results.map(\.trashedURL) { #expect(exists(url)) }
  }

  @Test func deletesFileAndFolderPermanently() async throws {
    let (tree, root) = try await scannedTree()
    let file = try #require(child(root, "a.bin"))
    let folder = try #require(child(root, "docs"))
    let results = await DeletionService(root: tree.root).delete(
      nodes: [file, folder], mode: .deletePermanently)

    #expect(results.allSatisfy { $0.succeeded })
    #expect(results.allSatisfy { $0.trashedURL == nil })
    #expect(!exists(file.url))
    #expect(!exists(folder.url))
    #expect(exists(tree.root))
  }

  @Test func descendantOfDeletedFolderCountsAsDeleted() async throws {
    let (tree, root) = try await scannedTree()
    let folder = try #require(child(root, "docs"))
    let inner = try #require(child(folder, "b.bin"))
    let results = await DeletionService(root: tree.root).delete(
      nodes: [folder, inner], mode: .deletePermanently)

    #expect(results.allSatisfy { $0.succeeded })
    #expect(!exists(folder.url))
  }

  @Test func refusesScanRootAndOutsidePaths() async throws {
    let (tree, root) = try await scannedTree()
    let other = try TempTree()
    let outsideURL = try other.file("x.bin", bytes: 10)
    let outside = FileNode(name: "x.bin", url: outsideURL, size: 10)
    let service = DeletionService(root: tree.root)
    let results = await service.delete(nodes: [root, outside], mode: .deletePermanently)
    defer { withExtendedLifetime(other) {} }

    #expect(results.map(\.error) == [.scanRoot, .outsideScanRoot])
    #expect(exists(tree.root))
    #expect(exists(outsideURL))
  }

  /// A node whose tree was released has no known path. Its URL must not resolve against the
  /// working directory, where a file of the same name could sit inside the scan root.
  @Test func refusesNodesWithoutAPathAndRelativeURLs() async throws {
    let tree = try TempTree()
    let url = try tree.file("x.bin", bytes: 10)
    let service = DeletionService(root: tree.root)
    func detachedChild() -> FileNode {
      let parent = FileNode(
        name: "p", url: tree.root,
        children: [FileNode(name: "x.bin", url: url, size: 10)])
      return parent.children[0]
    }
    let orphan = detachedChild()

    #expect(!orphan.url.isFileURL)
    #expect(service.refusal(for: orphan.url) == .outsideScanRoot)
    #expect(service.refusal(for: URL(string: "x.bin")!) == .outsideScanRoot)
    let results = await service.delete(nodes: [orphan], mode: .deletePermanently)
    #expect(results.map(\.error) == [.outsideScanRoot])
    #expect(exists(url))
  }

  @Test func refusesProtectedLocations() {
    let service = DeletionService(root: URL(fileURLWithPath: "/"))
    #expect(service.refusal(for: URL(fileURLWithPath: "/")) == .scanRoot)
    #expect(service.refusal(for: URL(fileURLWithPath: "/System/Library")) == .systemPath)
    #expect(service.refusal(for: URL(fileURLWithPath: "/usr/bin/true")) == .systemPath)
    #expect(service.refusal(for: URL(fileURLWithPath: "/bin")) == .systemPath)
    #expect(service.refusal(for: URL(fileURLWithPath: "/sbin/mount")) == .systemPath)
    #expect(service.refusal(for: URL(fileURLWithPath: "/Library/Fonts")) == .systemPath)
    #expect(
      service.refusal(for: FileManager.default.homeDirectoryForCurrentUser) == .homeFolder)
    #expect(service.refusal(for: URL(fileURLWithPath: "/Users/someone/file.txt")) == nil)
    #expect(service.refusal(for: URL(fileURLWithPath: "/Systemic")) == nil)
  }

  @Test func refusesVolumeRoot() {
    let service = DeletionService(root: URL(fileURLWithPath: "/Users"))
    #expect(service.refusal(for: URL(fileURLWithPath: "/")) == .volumeRoot)
  }

  @Test func refusesAppleAppsInApplications() throws {
    let safari = URL(fileURLWithPath: "/Applications/Safari.app")
    try #require(Bundle(url: safari) != nil, "Safari is not in /Applications")
    let service = DeletionService(root: URL(fileURLWithPath: "/Applications"))
    #expect(service.refusal(for: safari) == .systemApp)
    // Apple apps may be links into /System, so their contents can be refused as system paths.
    #expect(service.refusal(for: safari.appendingPathComponent("Contents")) != nil)
    let thirdParty = URL(fileURLWithPath: "/Applications/NotInstalled-\(UUID().uuidString).app")
    #expect(service.refusal(for: thirdParty) == nil)
    #expect(service.refusal(for: thirdParty.appendingPathComponent("Contents")) == nil)
  }

  @Test func refusesAppleAppsInApplicationsSubfolders() throws {
    let utilities = URL(fileURLWithPath: "/Applications/Utilities")
    let apps = (try? FileManager.default.contentsOfDirectory(atPath: utilities.path)) ?? []
    let appleApp = apps.map { utilities.appendingPathComponent($0) }.first {
      Bundle(url: $0)?.bundleIdentifier?.hasPrefix("com.apple.") == true
    }
    try #require(appleApp != nil, "No Apple app in /Applications/Utilities")
    let service = DeletionService(root: URL(fileURLWithPath: "/Applications"))
    #expect(service.refusal(for: appleApp!) == .systemApp)
    #expect(service.refusal(for: appleApp!.appendingPathComponent("Contents")) != nil)
  }

  @Test func refusesApplicationsSubfoldersThatHoldAnAppleApp() throws {
    let utilities = URL(fileURLWithPath: "/Applications/Utilities")
    if DeletionService.containsSystemApp(utilities.path) {
      let service = DeletionService(root: URL(fileURLWithPath: "/"))
      #expect(service.refusal(for: utilities) == .systemApp)
    }
    let tree = try TempTree()
    defer { withExtendedLifetime(tree) {} }
    func app(_ path: String, id: String) throws {
      let contents = try tree.folder("\(path)/Contents")
      let plist = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
      try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
    }
    try app("third/Tool.app", id: "com.example.tool")
    try app("apple/nested/Fake.app", id: "com.apple.fake")
    #expect(!DeletionService.containsSystemApp(tree.root.appendingPathComponent("third").path))
    #expect(DeletionService.containsSystemApp(tree.root.appendingPathComponent("apple").path))
    #expect(DeletionService.containsSystemApp(tree.root.path))
  }

  @Test func refusesFoldersThatContainProtectedLocations() {
    let service = DeletionService(
      root: URL(fileURLWithPath: "/"), homeDirectory: URL(fileURLWithPath: "/Users/someone"))
    #expect(service.refusal(for: URL(fileURLWithPath: "/Users")) == .homeFolder)
    #expect(service.refusal(for: URL(fileURLWithPath: "/Users/someone")) == .homeFolder)
    #expect(service.refusal(for: URL(fileURLWithPath: "/Users/someone/Documents")) == nil)
    #expect(service.refusal(for: URL(fileURLWithPath: "/Applications")) == .systemApp)
    #expect(service.refusal(for: URL(fileURLWithPath: "/private")) == .systemPath)
    #expect(service.refusal(for: URL(fileURLWithPath: "/private/var")) == .systemPath)
    #expect(service.refusal(for: URL(fileURLWithPath: "/private/tmp")) == .systemPath)
    #expect(service.refusal(for: URL(fileURLWithPath: "/private/tmp/scratch")) == nil)
  }

  @Test func refusesHomeFolderAndItsParentsInsideTheScanRoot() throws {
    let tree = try TempTree()
    let home = try tree.folder("people/me")
    let service = DeletionService(root: tree.root, homeDirectory: home)
    #expect(service.refusal(for: home) == .homeFolder)
    #expect(service.refusal(for: tree.root.appendingPathComponent("people")) == .homeFolder)
    #expect(service.refusal(for: home.appendingPathComponent("notes.txt")) == nil)
  }

  @Test(
    .enabled(
      if: (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes"))?.isEmpty == false)
  )
  func refusesFoldersThatContainMountedVolumes() {
    let mounted = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? [])
      .filter { $0.path.hasPrefix("/Volumes/") }
    guard !mounted.isEmpty else { return }
    let service = DeletionService(root: URL(fileURLWithPath: "/"))
    #expect(service.refusal(for: URL(fileURLWithPath: "/Volumes")) == .volumeRoot)
  }

  @Test func reportsPartialFailuresPerItem() async throws {
    let (tree, root) = try await scannedTree()
    let file = try #require(child(root, "a.bin"))
    let missing = FileNode(
      name: "gone.bin", url: tree.root.appendingPathComponent("gone.bin"), size: 1)
    let results = await DeletionService(root: tree.root).delete(
      nodes: [missing, file], mode: .deletePermanently)

    #expect(results.count == 2)
    guard case .failed = results[0].error else {
      Issue.record(
        "expected a failure for the missing file, got \(String(describing: results[0].error))")
      return
    }
    #expect(results[1].succeeded)
    #expect(!exists(file.url))
  }

  @Test func restorePutsATrashedFileBack() async throws {
    let (tree, root) = try await scannedTree()
    defer { withExtendedLifetime(tree) {} }
    let file = try #require(child(root, "a.bin"))
    let service = DeletionService(root: tree.root)
    let results = await service.delete(nodes: [file], mode: .moveToTrash)
    let trashed = try #require(results.first?.trashedURL)
    defer { try? FileManager.default.removeItem(at: trashed) }

    #expect(await service.restore(trashedURL: trashed, to: file.url) == nil)
    #expect(exists(file.url))
    #expect(!exists(trashed))
  }

  @Test func restoreNeverOverwritesAnItemAtTheOriginal() async throws {
    let (tree, root) = try await scannedTree()
    defer { withExtendedLifetime(tree) {} }
    let file = try #require(child(root, "a.bin"))
    let service = DeletionService(root: tree.root)
    let results = await service.delete(nodes: [file], mode: .moveToTrash)
    let trashed = try #require(results.first?.trashedURL)
    defer { try? FileManager.default.removeItem(at: trashed) }
    try tree.file("a.bin", bytes: 10)

    let error = await service.restore(trashedURL: trashed, to: file.url)

    #expect(error == .failed("An item with that name already exists."))
    #expect(try Data(contentsOf: file.url).count == 10)
    #expect(exists(trashed))
  }

  @Test func restoreRefusesATargetOutsideTheScanRoot() async throws {
    let (tree, root) = try await scannedTree()
    defer { withExtendedLifetime(tree) {} }
    let file = try #require(child(root, "a.bin"))
    let service = DeletionService(root: tree.root)
    let results = await service.delete(nodes: [file], mode: .moveToTrash)
    let trashed = try #require(results.first?.trashedURL)
    defer { try? FileManager.default.removeItem(at: trashed) }
    let other = try TempTree()
    defer { withExtendedLifetime(other) {} }
    let target = other.root.appendingPathComponent("a.bin")

    #expect(await service.restore(trashedURL: trashed, to: target) == .outsideScanRoot)
    #expect(!exists(target))
    #expect(exists(trashed))
  }

  @Test func restoreReportsAnItemThatIsNoLongerInTheTrash() async throws {
    let tree = try TempTree()
    defer { withExtendedLifetime(tree) {} }
    let service = DeletionService(root: tree.root)
    let missing = tree.root.appendingPathComponent("gone.bin")
    let target = tree.root.appendingPathComponent("back.bin")

    #expect(
      await service.restore(trashedURL: missing, to: target)
        == .failed("The item is no longer in the Trash."))
    #expect(!exists(target))
  }
}

@Suite struct FileNodeRemovalTests {
  private func makeTree() -> (root: FileNode, docs: FileNode, deep: FileNode, big: FileNode) {
    let base = URL(fileURLWithPath: "/tmp/spacer-model")
    let deep = FileNode(
      name: "deep.bin", url: base.appendingPathComponent("docs/sub/deep.bin"), size: 70)
    let sub = FileNode(name: "sub", url: base.appendingPathComponent("docs/sub"), children: [deep])
    let small = FileNode(
      name: "small.bin", url: base.appendingPathComponent("docs/small.bin"), size: 10)
    let docs = FileNode(
      name: "docs", url: base.appendingPathComponent("docs"), children: [sub, small])
    let big = FileNode(name: "big.bin", url: base.appendingPathComponent("big.bin"), size: 50)
    let root = FileNode(name: "root", url: base, children: [docs, big])
    return (root, docs, deep, big)
  }

  @Test func removeUpdatesEveryAncestor() throws {
    let (root, docs, deep, _) = makeTree()
    let sub = try #require(deep.parent)
    #expect(root.size == 130)
    #expect(root.itemCount == 6)

    deep.remove()

    #expect(deep.parent == nil)
    #expect(sub.children.isEmpty)
    #expect(sub.size == 0)
    #expect(sub.itemCount == 1)
    #expect(docs.size == 10)
    #expect(docs.itemCount == 3)
    #expect(root.size == 60)
    #expect(root.itemCount == 5)
  }

  @Test func removeKeepsAncestorsSorted() {
    let (root, docs, deep, big) = makeTree()
    #expect(root.children.map(\.name) == ["docs", "big.bin"])
    deep.remove()
    #expect(root.children.map(\.name) == ["big.bin", "docs"])
    #expect(root.children.first === big)
    #expect(docs.parent === root)
  }

  @Test func removeFolderSubtractsSubtree() {
    let (root, docs, _, _) = makeTree()
    docs.remove()
    #expect(root.children.map(\.name) == ["big.bin"])
    #expect(root.size == 50)
    #expect(root.itemCount == 2)
  }

  @Test func removeRootIsNoOp() {
    let (root, _, _, _) = makeTree()
    root.remove()
    #expect(root.size == 130)
    #expect(root.itemCount == 6)
  }

  @Test func attachAfterRemoveRestoresEveryAncestor() throws {
    let (root, docs, deep, _) = makeTree()
    let sub = try #require(deep.parent)
    let stats = root.categoryStats
    let path = deep.url.path

    deep.remove()
    sub.attach(deep)

    #expect(deep.parent === sub)
    #expect(sub.children.map(\.name) == ["deep.bin"])
    #expect(sub.size == 70)
    #expect(sub.itemCount == 2)
    #expect(docs.size == 80)
    #expect(docs.itemCount == 4)
    #expect(root.size == 130)
    #expect(root.itemCount == 6)
    #expect(root.categoryStats == stats)
    #expect(deep.url.path == path)
  }

  @Test func attachKeepsAncestorsSorted() {
    let (root, _, _, big) = makeTree()
    big.remove()
    let huge = FileNode(name: "huge.bin", url: URL(fileURLWithPath: "/tmp/huge.bin"), size: 100)

    root.attach(huge)

    #expect(root.children.map(\.name) == ["huge.bin", "docs"])
    #expect(root.size == 180)
    #expect(root.itemCount == 6)
  }

  @Test func attachResortsAnAncestorAboveTheAttachPoint() throws {
    let (root, docs, deep, big) = makeTree()
    let sub = try #require(deep.parent)
    deep.remove()
    #expect(root.children.first === big)

    sub.attach(deep)

    #expect(root.children.first === docs)
    #expect(root.children.map(\.name) == ["docs", "big.bin"])
  }

  @Test func attachUnderAnAppBundleCountsAsApps() {
    let base = URL(fileURLWithPath: "/tmp/spacer-model")
    let stub = FileNode(
      name: "stub", url: base.appendingPathComponent("Tool.app/stub"), size: 30)
    let app = FileNode(
      name: "Tool.app", url: base.appendingPathComponent("Tool.app"), children: [stub],
      isPackage: true)
    let big = FileNode(name: "big.bin", url: base.appendingPathComponent("big.bin"), size: 50)
    let root = FileNode(name: "root", url: base, children: [app, big])
    let movie = FileNode(
      name: "movie.mov", url: base.appendingPathComponent("Tool.app/movie.mov"), size: 20)
    #expect(app.isAppBundle)
    #expect(root.categoryStats[.apps] == 30)

    app.attach(movie)

    #expect(app.size == 50)
    #expect(app.categoryStats[.video] == 20)
    #expect(root.size == 100)
    #expect(root.categoryStats[.apps] == 50)
    #expect(root.categoryStats[.video] == 0)
    #expect(root.categoryStats.total == root.size)

    movie.remove()

    #expect(root.size == 80)
    #expect(root.categoryStats[.apps] == 30)
  }
}
