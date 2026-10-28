import Foundation
import Testing

@testable import SpacerCore

/// A temporary folder that is removed when the test ends.
final class TempTree {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpacerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    // Make every folder writable again so that removal succeeds after permission tests.
    if let walker = FileManager.default.enumerator(atPath: root.path) {
      for case let path as String in walker {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(path).path)
      }
    }
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  func file(_ path: String, bytes: Int) throws -> URL {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
    return url
  }

  /// A file of random bytes, which APFS does not shrink, so its size is its real size.
  @discardableResult
  func randomFile(_ path: String, bytes: Int) throws -> URL {
    let url = root.appendingPathComponent(path)
    try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).write(to: url)
    return url
  }

  /// Makes `to` an APFS clone of `from`: a new file that shares its data, without a copy.
  func clone(_ from: URL, to: URL) throws {
    guard clonefile(from.path, to.path, 0) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// Whether the temp folder is on APFS, where `clone` makes clones. Clone tests are skipped
  /// on other volumes.
  static let isAPFS: Bool = {
    var info = statfs()
    guard statfs(FileManager.default.temporaryDirectory.path, &info) == 0 else { return false }
    let name = withUnsafeBytes(of: info.f_fstypename) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    return name == "apfs"
  }()

  @discardableResult
  func folder(_ path: String) throws -> URL {
    let url = root.appendingPathComponent(path, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func allocatedSize(_ url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [
      .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ])
    return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
  }
}

private func child(_ node: FileNode, _ name: String) -> FileNode? {
  node.children.first { $0.name == name }
}

private func allNodes(_ node: FileNode) -> [FileNode] {
  [node] + node.children.flatMap(allNodes)
}

@Suite struct DiskScannerTests {
  @Test func sizesAddUp() async throws {
    let tree = try TempTree()
    let files = [
      try tree.file("a.bin", bytes: 10_000),
      try tree.file("docs/b.bin", bytes: 50_000),
      try tree.file("docs/deep/c.bin", bytes: 120_000),
      try tree.file("media/d.bin", bytes: 300_000),
      try tree.file("media/e.bin", bytes: 1),
    ]
    try tree.folder("empty")
    let expected = try files.reduce(Int64(0)) { $0 + (try tree.allocatedSize($1)) }

    let root = try await DiskScanner().scan(tree.root)

    #expect(root.isDirectory)
    #expect(root.size == expected)
    for node in allNodes(root) where node.isDirectory {
      #expect(node.size == node.children.reduce(0) { $0 + $1.size })
      #expect(node.itemCount == node.children.reduce(1) { $0 + $1.itemCount })
      for c in node.children {
        #expect(c.parent === node)
      }
    }
    // root + a.bin + docs, b.bin, deep, c.bin + media, d.bin, e.bin + empty
    #expect(root.itemCount == 10)
    #expect(child(root, "empty")?.size == 0)
    #expect(child(root, "docs").flatMap { child($0, "deep") }?.ancestry.map(\.name).count == 3)
  }

  @Test func childrenAreSortedLargestFirst() async throws {
    let tree = try TempTree()
    try tree.file("small.bin", bytes: 1_000)
    try tree.file("big.bin", bytes: 400_000)
    try tree.file("mid/x.bin", bytes: 100_000)

    let root = try await DiskScanner().scan(tree.root)

    #expect(root.children.map(\.name) == ["big.bin", "mid", "small.bin"])
    for node in allNodes(root) {
      #expect(node.children.map(\.size) == node.children.map(\.size).sorted(by: >))
    }
  }

  @Test func symlinksAreIgnored() async throws {
    let tree = try TempTree()
    let real = try tree.file("real/data.bin", bytes: 200_000)
    let outside = try TempTree()
    let big = try outside.file("big.bin", bytes: 500_000)
    try FileManager.default.createSymbolicLink(
      at: tree.root.appendingPathComponent("link-to-file"), withDestinationURL: big)
    try FileManager.default.createSymbolicLink(
      at: tree.root.appendingPathComponent("link-to-dir"), withDestinationURL: outside.root)

    let root = try await DiskScanner().scan(tree.root)
    defer { withExtendedLifetime(outside) {} }

    #expect(root.children.map(\.name) == ["real"])
    #expect(root.size == (try tree.allocatedSize(real)))
  }

  @Test func symlinkedRootIsScannedAtItsTarget() async throws {
    let target = try TempTree()
    let data = try target.file("data.bin", bytes: 100_000)
    let links = try TempTree()
    let link = links.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.root)
    defer { withExtendedLifetime((target, links)) {} }

    let root = try await DiskScanner().scan(link)

    #expect(root.isDirectory)
    #expect(root.children.map(\.name) == ["data.bin"])
    #expect(root.size == (try target.allocatedSize(data)))
  }

  @Test func privateSystemLinkRootIsScannedAsAFolder() async throws {
    // Foundation turns /private/tmp into /tmp, which is itself a link.
    let root = try await DiskScanner().scan(URL(fileURLWithPath: "/private/tmp"))
    #expect(root.isDirectory)
    #expect(root.url.path == "/private/tmp")
  }

  @Test func hardLinksAreCountedOnce() async throws {
    let tree = try TempTree()
    let original = try tree.file("one/original.bin", bytes: 256_000)
    try tree.folder("two")
    try FileManager.default.linkItem(
      at: original, to: tree.root.appendingPathComponent("two/link.bin"))

    let root = try await DiskScanner().scan(tree.root)

    let fileCount = allNodes(root).filter { !$0.isDirectory }.count
    #expect(fileCount == 1)
    #expect(root.size == (try tree.allocatedSize(original)))
  }

  /// Three clones of one 4 MB file share its blocks, so the folder is about 4 MB, not 12 MB.
  @Test(.enabled(if: TempTree.isAPFS)) func apfsClonesAreCountedOnce() async throws {
    let tree = try TempTree()
    let base = try tree.randomFile("base.bin", bytes: 4 * 1_048_576)
    try tree.clone(base, to: tree.root.appendingPathComponent("clone1.bin"))
    try tree.clone(base, to: tree.root.appendingPathComponent("clone2.bin"))
    let oneCopy = try tree.allocatedSize(base)

    let root = try await DiskScanner().scan(tree.root)

    #expect(root.size == oneCopy)
    #expect(allNodes(root).filter { !$0.isDirectory }.count == 3)
  }

  /// Clones whose original was deleted keep its inode as their clone ID and report no private
  /// bytes while two or more remain, but the blocks are still in use: the total is one copy.
  @Test(.enabled(if: TempTree.isAPFS), arguments: [1, 2, 3])
  func clonesOfADeletedOriginalAreCountedOnce(survivors: Int) async throws {
    let tree = try TempTree()
    let base = try tree.randomFile("base.bin", bytes: 4 * 1_048_576)
    let oneCopy = try tree.allocatedSize(base)
    for index in 1...survivors {
      try tree.clone(base, to: tree.root.appendingPathComponent("clone\(index).bin"))
    }
    try FileManager.default.removeItem(at: base)

    let root = try await DiskScanner().scan(tree.root)

    #expect(root.size == oneCopy)
    #expect(allNodes(root).filter { !$0.isDirectory }.count == survivors)
  }

  /// A clone whose original exists outside the scanned folder counts only its own bytes.
  @Test(.enabled(if: TempTree.isAPFS)) func cloneWithOriginalOutsideTheScanCountsPrivateBytes()
    async throws
  {
    let tree = try TempTree()
    try tree.folder("outside")
    try tree.folder("inside")
    let base = try tree.randomFile("outside/base.bin", bytes: 4 * 1_048_576)
    try tree.clone(base, to: tree.root.appendingPathComponent("inside/clone1.bin"))
    try tree.clone(base, to: tree.root.appendingPathComponent("inside/clone2.bin"))

    let root = try await DiskScanner().scan(tree.root.appendingPathComponent("inside"))

    #expect(root.size == 0)
  }

  /// A clone written after cloning gets its own clone ID, so the blocks it still shares with its
  /// siblings are counted again. This pins that known approximation: the total is more than one
  /// copy plus the written part, and less than three full copies.
  @Test(.enabled(if: TempTree.isAPFS)) func modifiedCloneKeepsItsOwnClonedBlocks() async throws {
    let tree = try TempTree()
    let base = try tree.randomFile("base.bin", bytes: 4 * 1_048_576)
    try tree.clone(base, to: tree.root.appendingPathComponent("clone1.bin"))
    let modified = tree.root.appendingPathComponent("clone2.bin")
    try tree.clone(base, to: modified)
    let oneCopy = try tree.allocatedSize(base)
    let handle = try FileHandle(forWritingTo: modified)
    try handle.seek(toOffset: 1_048_576)
    try handle.write(contentsOf: Data(repeating: 9, count: 65_536))
    try handle.close()
    let writtenPart = try #require(DirectoryReader.privateSize(atPath: modified.path))

    let root = try await DiskScanner().scan(tree.root)

    #expect(writtenPart > 0 && writtenPart < oneCopy)
    #expect(root.size >= oneCopy + writtenPart)
    #expect(root.size < 3 * oneCopy)
  }

  @Test func countedSizeCountsOnlyTheOwnBytesOfAClone() {
    let mb: Int64 = 1_048_576
    func file(inode: UInt64, cloneID: UInt64?, privateSize: Int64? = nil) -> DirectoryEntry {
      DirectoryEntry(
        name: "f", kind: .file, device: 1, inode: inode, linkCount: 1, allocatedSize: 4 * mb,
        isMountPoint: false, privateSize: privateSize, cloneID: cloneID)
    }
    // No clone data (non-APFS), a file that is its own data stream, and ID 0: not clones.
    #expect(!file(inode: 5, cloneID: nil).isClone)
    #expect(!file(inode: 5, cloneID: 5).isClone)
    #expect(!file(inode: 5, cloneID: 0).isClone)
    #expect(file(inode: 5, cloneID: nil).countedSize == 4 * mb)
    #expect(file(inode: 5, cloneID: 5).countedSize == 4 * mb)
    // A clone has another file's ID and counts its private bytes, never more than its allocation.
    #expect(file(inode: 6, cloneID: 5).isClone)
    #expect(file(inode: 6, cloneID: 5, privateSize: 0).countedSize == 0)
    #expect(file(inode: 6, cloneID: 5, privateSize: 65_536).countedSize == 65_536)
    #expect(file(inode: 6, cloneID: 5, privateSize: 9 * mb).countedSize == 4 * mb)
    // A clone whose private size cannot be read counts in full.
    #expect(file(inode: 6, cloneID: 5, privateSize: nil).countedSize == 4 * mb)
  }

  @Test func packagesAreScannedAsFolders() async throws {
    let tree = try TempTree()
    try tree.file("Tool.app/Contents/MacOS/Tool", bytes: 40_000)

    let root = try await DiskScanner().scan(tree.root)

    let app = try #require(child(root, "Tool.app"))
    #expect(app.isDirectory)
    #expect(app.isPackage)
    #expect(app.size > 0)
  }

  @Test func unreadableFolderIsFlagged() async throws {
    let tree = try TempTree()
    try tree.file("open/ok.bin", bytes: 10_000)
    try tree.file("locked/secret.bin", bytes: 10_000)
    let locked = tree.root.appendingPathComponent("locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

    let root = try await DiskScanner().scan(tree.root)

    let lockedNode = try #require(child(root, "locked"))
    #expect(lockedNode.accessDenied)
    #expect(lockedNode.children.isEmpty)
    #expect(child(root, "open")?.accessDenied == false)
  }

  @Test func scanningASingleFileReturnsAFileNode() async throws {
    let tree = try TempTree()
    let file = try tree.file("solo.bin", bytes: 30_000)

    let root = try await DiskScanner().scan(file)

    #expect(!root.isDirectory)
    #expect(root.size == (try tree.allocatedSize(file)))
  }

  /// A single-file root keeps its real name, so its extension still sets its category.
  @Test func scannedFileRootKeepsItsExtension() async throws {
    let tree = try TempTree()
    let file = try tree.file("movie.mp4", bytes: 30_000)

    let root = try await DiskScanner().scan(file)

    #expect(root.name == "movie.mp4")
    #expect(FileCategory.of(root) == FileCategory.of(extension: "mp4"))
    #expect(FileCategory.of(root) != .other)
  }

  @Test func missingPathThrows() async throws {
    let tree = try TempTree()
    await #expect(throws: (any Error).self) {
      try await DiskScanner().scan(tree.root.appendingPathComponent("nope"))
    }
  }

  @Test func skipRuleCoversMirrorsAndMounts() {
    #expect(DiskScanner.rootMirrorNames == [".nofollow", ".resolve"])
    func folder(_ name: String, device: Int32 = 1, mount: Bool = false) -> DirectoryEntry {
      DirectoryEntry(
        name: name, kind: .directory, device: device, inode: 1, linkCount: 1, allocatedSize: 0,
        isMountPoint: mount)
    }
    func skipped(_ entry: DirectoryEntry, underVolumeRoot: Bool) -> Bool {
      DiskScanner.skipsFolder(entry, parentIsVolumeRoot: underVolumeRoot)
    }

    // Mirrors directly under a volume root are skipped.
    #expect(skipped(folder(".nofollow"), underVolumeRoot: true))
    #expect(skipped(folder(".resolve"), underVolumeRoot: true))
    // Elsewhere they are ordinary folders, and so is any other name under a volume root.
    #expect(!skipped(folder(".nofollow"), underVolumeRoot: false))
    #expect(!skipped(folder("Users"), underVolumeRoot: true))
    #expect(!skipped(folder("Users"), underVolumeRoot: false))
    // A mount point is skipped on any device.
    #expect(skipped(folder("Mounted", mount: true), underVolumeRoot: false))
    #expect(skipped(folder("Mounted", device: 0, mount: true), underVolumeRoot: true))
    // The device does not decide: a firmlink target on another device, and an unknown device
    // (0), are scanned unless they are mount points.
    #expect(!skipped(folder("Users", device: 2), underVolumeRoot: true))
    #expect(!skipped(folder("Users", device: 0), underVolumeRoot: true))
    #expect(!skipped(folder("Users", device: 0), underVolumeRoot: false))
    // A cloud-only (dataless) folder is skipped anywhere: listing it downloads it.
    var cloudOnly = folder("Other computers")
    cloudOnly.flags = UInt32(SF_DATALESS)
    #expect(cloudOnly.isDataless)
    #expect(skipped(cloudOnly, underVolumeRoot: false))
    #expect(skipped(cloudOnly, underVolumeRoot: true))
    var hidden = folder("Hidden")
    hidden.flags = UInt32(UF_HIDDEN)
    #expect(!hidden.isDataless)
    #expect(!skipped(hidden, underVolumeRoot: false))
  }

  /// A mirror name is only skipped under a volume root. The temp folder is not one, so
  /// `.nofollow` and `.resolve` are scanned like any other folder here.
  @Test func rootMirrorNamesAreScannedOutsideVolumeRoots() async throws {
    let tree = try TempTree()
    let a = try tree.file(".nofollow/a.bin", bytes: 4_096)
    let b = try tree.file(".resolve/b.bin", bytes: 8_192)

    let root = try await DiskScanner().scan(tree.root)

    #expect(child(root, ".nofollow")?.size == (try tree.allocatedSize(a)))
    #expect(child(root, ".resolve")?.size == (try tree.allocatedSize(b)))
    #expect(root.size == (try tree.allocatedSize(a)) + (try tree.allocatedSize(b)))
  }

  /// Scans `/` and stops once the preview lists a few of its folders. The preview only holds
  /// folders the scanner walks, so the root mirrors must not be in it.
  @Test func rootScanNeverListsTheRootMirrors() async throws {
    let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
    let scan = Task {
      try await DiskScanner(progressInterval: .zero, previewInterval: .zero).scan(
        URL(fileURLWithPath: "/"), progress: continuation)
    }
    var listed: [String] = []
    for await event in stream {
      guard let preview = event.preview else { continue }
      listed = preview.children.map(\.name)
      if listed.count >= 5 { break }
    }
    scan.cancel()
    _ = try? await scan.value

    #expect(listed.count >= 5)
    #expect(Set(listed).isDisjoint(with: DiskScanner.rootMirrorNames))
  }

  @Test func cancellationStopsTheScan() async throws {
    let tree = try TempTree()
    for i in 0..<40 {
      for j in 0..<20 {
        try tree.file("d\(i)/e\(j)/f.bin", bytes: 10)
      }
    }
    let scanner = DiskScanner(maxConcurrency: 2)
    let task = Task { try await scanner.scan(tree.root) }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test func progressEventsAreEmitted() async throws {
    let tree = try TempTree()
    for i in 0..<5 {
      try tree.file("dir\(i)/file.bin", bytes: 4_096)
    }
    try tree.file("top.bin", bytes: 4_096)
    let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)

    let root = try await DiskScanner(progressInterval: .zero).scan(
      tree.root, progress: continuation)

    var events: [ScanProgress] = []
    for await event in stream {
      events.append(event)
    }
    #expect(events.count > 1)
    let last = try #require(events.last)
    #expect(last.filesScanned == 6)
    #expect(last.bytesScanned == root.size)
    #expect(events.map(\.filesScanned) == events.map(\.filesScanned).sorted())
  }

  @Test func progressIsThrottled() async throws {
    let tree = try TempTree()
    for i in 0..<30 {
      try tree.file("dir\(i)/file.bin", bytes: 10)
    }
    let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)

    _ = try await DiskScanner(progressInterval: .seconds(60)).scan(
      tree.root, progress: continuation)

    var count = 0
    for await _ in stream {
      count += 1
    }
    // The first update and the final one; everything in between falls inside the interval.
    #expect(count == 2)
  }

  @Test func previewShowsTwoLevelsAndSumsDeeperContent() async throws {
    let tree = try TempTree()
    try tree.file("top.bin", bytes: 4_096)
    try tree.file("a/f.bin", bytes: 8_192)
    try tree.file("a/x/g.bin", bytes: 4_096)
    try tree.file("a/x/deep/h.bin", bytes: 16_384)
    try tree.file("b/i.bin", bytes: 4_096)
    let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)

    let root = try await DiskScanner(progressInterval: .zero, previewInterval: .zero).scan(
      tree.root, progress: continuation)

    var previews: [FileNode] = []
    for await event in stream {
      if let preview = event.preview { previews.append(preview) }
    }
    let first = try #require(previews.first)
    #expect(first.url == root.url)
    let preview = try #require(previews.last)
    #expect(preview !== root)
    #expect(preview.size == root.size)
    #expect(Set(preview.children.map(\.name)) == Set(root.children.map(\.name)))
    let a = try #require(child(preview, "a"))
    #expect(Set(a.children.map(\.name)) == ["f.bin", "x"])
    // a/x is at the preview depth: everything below it is summed into one block.
    let x = try #require(child(a, "x"))
    #expect(x.children.isEmpty)
    #expect(x.size == child(child(root, "a")!, "x")?.size)
    #expect(child(preview, "b")?.size == child(root, "b")?.size)
    #expect(previews.map(\.size) == previews.map(\.size).sorted())
  }

  /// With a long preview interval only the first update rebuilds the preview during the scan,
  /// so the final event must rebuild it to include everything that came in since.
  @Test func finalPreviewIsCompleteEvenWithinThePreviewInterval() async throws {
    let tree = try TempTree()
    try tree.file("top.bin", bytes: 4_096)
    for i in 0..<5 { try tree.file("d\(i)/x/f.bin", bytes: 4_096) }
    let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)

    let root = try await DiskScanner(progressInterval: .zero, previewInterval: .seconds(3600))
      .scan(tree.root, progress: continuation)

    var last: ScanProgress?
    for await event in stream { last = event }
    let preview = try #require(last?.preview)
    #expect(preview.size == root.size)
    #expect(Set(preview.children.map(\.name)) == Set(root.children.map(\.name)))
    for i in 0..<5 {
      let shown = child(preview, "d\(i)").flatMap { child($0, "x") }
      let scanned = child(root, "d\(i)").flatMap { child($0, "x") }
      #expect(shown != nil && shown?.size == scanned?.size)
    }
  }

  @Test func fileRootHasNoPreview() async throws {
    let tree = try TempTree()
    try tree.file("a/f.bin", bytes: 4_096)
    let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)

    let root = try await DiskScanner(progressInterval: .zero).scan(
      tree.root.appendingPathComponent("a/f.bin"), progress: continuation)

    #expect(!root.isDirectory)
    for await event in stream {
      #expect(event.preview == nil)
    }
  }

  @Test func resultDoesNotDependOnConcurrency() async throws {
    let tree = try TempTree()
    for i in 0..<6 {
      for j in 0..<4 {
        try tree.file("d\(i)/e\(j)/f\(j)/g.bin", bytes: 1_000 * (i + j + 1))
      }
      try tree.file("d\(i)/top.bin", bytes: 500)
    }
    func shape(_ node: FileNode) -> [String] {
      ["\(node.url.path) \(node.size) \(node.itemCount)"] + node.children.flatMap(shape)
    }

    let serial = try await DiskScanner(maxConcurrency: 1).scan(tree.root)
    let parallel = try await DiskScanner(maxConcurrency: 16).scan(tree.root)

    #expect(shape(serial) == shape(parallel))
    #expect(serial.itemCount == 1 + 6 * (1 + 1 + 4 * 3))
  }

  @Test func explicitSizeFolderKeepsItsSize() {
    let file = FileNode(name: "f", url: URL(fileURLWithPath: "/p/f"), size: 10)
    let folder = FileNode(
      name: "p", url: URL(fileURLWithPath: "/p"), children: [file], size: 50,
      accessDenied: true)
    #expect(folder.size == 50)
    #expect(folder.isDirectory)
    #expect(folder.accessDenied)
    #expect(file.parent === folder)
  }
}
