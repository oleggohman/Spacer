import Foundation
import Synchronization

/// A snapshot of how far a scan has got.
public struct ScanProgress: Sendable, Equatable {
  public var filesScanned: Int
  public var bytesScanned: Int64
  public var currentPath: String
  /// A rough tree of what has been found so far: the root and two levels of folders, with
  /// deeper content summed into its level-two folder. Nil until the first snapshot is taken.
  /// A new snapshot is a new tree; nodes are never shared with the final result.
  public var preview: FileNode?

  public init(
    filesScanned: Int, bytesScanned: Int64, currentPath: String, preview: FileNode? = nil
  ) {
    self.filesScanned = filesScanned
    self.bytesScanned = bytesScanned
    self.currentPath = currentPath
    self.preview = preview
  }
}

/// Walks a folder and builds a `FileNode` tree sized by allocated bytes.
///
/// Symbolic links are skipped, other volumes and the root mirrors are not entered, hard-linked
/// files are counted once, APFS clones count only their own bytes (`DirectoryEntry.countedSize`;
/// clones of a deleted original share their blocks once), and unreadable folders are kept as
/// nodes with `accessDenied` set.
public actor DiskScanner {
  public let maxConcurrency: Int
  public let progressInterval: Duration
  /// How often the preview tree in `ScanProgress` is rebuilt.
  public let previewInterval: Duration

  public init(
    maxConcurrency: Int = 16, progressInterval: Duration = .milliseconds(100),
    previewInterval: Duration = .milliseconds(500)
  ) {
    self.maxConcurrency = max(1, maxConcurrency)
    self.progressInterval = progressInterval
    self.previewInterval = previewInterval
  }

  /// Folders that macOS lists directly under the volume root (`/`) but that mirror the whole
  /// root, so walking them would count every file twice.
  static let rootMirrorNames: Set<String> = [".nofollow", ".resolve"]

  /// Whether a folder entry is left out of the scan. That is another volume mounted here (or an
  /// automount trigger), a cloud placeholder folder (its content is not on this disk, and
  /// listing it downloads it, which for a Google Drive "Other computers" backup can take hours),
  /// or a `rootMirrorNames` folder directly under a volume root. The device number is not used:
  /// the firmlinks of a system volume can report another device and must still be scanned, and
  /// a device that is unknown (0) must never drop a folder.
  static func skipsFolder(_ entry: DirectoryEntry, parentIsVolumeRoot: Bool) -> Bool {
    if entry.isMountPoint || entry.isDataless { return true }
    return parentIsVolumeRoot && rootMirrorNames.contains(entry.name)
  }

  /// Scans `url` and returns the root node.
  ///
  /// Progress is sent to `progress`, which is finished when the scan ends. Throws
  /// `CancellationError` when the calling task is cancelled.
  public func scan(
    _ url: URL, progress: AsyncStream<ScanProgress>.Continuation? = nil
  ) async throws -> FileNode {
    defer { progress?.finish() }
    let walker = ScanWalker(
      maxConcurrency: maxConcurrency, progressInterval: progressInterval,
      previewInterval: previewInterval, progress: progress)
    let root = try await walker.scanRoot(url.standardizedFileURL)
    walker.emitFinal(path: root.url.path)
    return root
  }
}

/// The shared state of one scan. Safe to use from the parallel child tasks.
final class ScanWalker: Sendable {
  /// A hard-linked inode, or the (device, clone ID) group of orphaned clones.
  private struct FileID: Hashable {
    var device: Int32
    var inode: UInt64
  }

  /// A folder of the preview tree. Only folders down to `previewDepth` get one.
  private struct PreviewFolder {
    var name: String
    var url: URL
    var isPackage: Bool
    var accessDenied: Bool
    /// The largest direct files, kept for folders above `previewDepth`.
    var files: [(name: String, url: URL, size: Int64)] = []
    /// Bytes not in `files` or `subfolders`: smaller files and, at `previewDepth`, everything below.
    var otherBytes: Int64 = 0
    var subfolders: [String] = []
  }

  /// What a folder reports to the preview tree.
  private enum PreviewUpdate {
    case none
    /// A folder at or above `previewDepth`, registered under its parent's path (nil for the root).
    case folder(PreviewFolder, parent: String?)
    /// Direct-file bytes of a deeper folder, added to the preview folder at this path.
    case bytes(Int64, into: String)
  }

  private struct Counters {
    var files = 0
    var bytes: Int64 = 0
    var lastEmit: ContinuousClock.Instant?
    var seenIdentities = Set<FileID>()
    var previewFolders: [String: PreviewFolder] = [:]
    var previewRoot: String?
    var previewChanged = false
    var lastPreview: ContinuousClock.Instant?
    var snapshot: FileNode?
  }

  static let keySet: Set<URLResourceKey> = [
    .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey,
    .fileAllocatedSizeKey,
  ]

  /// Folders down to this depth appear in the preview tree. Deeper content is summed into them.
  private static let previewDepth = 2
  /// The most direct files a preview folder lists. The rest only count toward its size.
  private static let previewFileLimit = 100

  private let maxConcurrency: Int
  private let progressInterval: Duration
  private let previewInterval: Duration
  private let progress: AsyncStream<ScanProgress>.Continuation?
  private let counters = Mutex(Counters())
  /// Child tasks running now. Subfolders get their own task while this is under
  /// `maxConcurrency`, at any depth; otherwise the parent scans them itself.
  private let activeTasks = Atomic<Int>(0)
  private let clock = ContinuousClock()

  init(
    maxConcurrency: Int, progressInterval: Duration, previewInterval: Duration = .zero,
    progress: AsyncStream<ScanProgress>.Continuation?
  ) {
    self.maxConcurrency = maxConcurrency
    self.progressInterval = progressInterval
    self.previewInterval = previewInterval
    self.progress = progress
  }

  func scanRoot(_ url: URL) async throws -> FileNode {
    try Task.checkCancellation()
    var url = url
    var values = try url.resourceValues(forKeys: Self.keySet)
    // A root that is a link (such as /tmp) is scanned at its target. Links inside are skipped.
    // `resolvingSymlinksInPath()` turns /private/tmp back into /tmp, so use realpath(3).
    if values.isSymbolicLink == true, let resolved = realpath(url.path, nil) {
      defer { free(resolved) }
      url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
      values = try url.resourceValues(forKeys: Self.keySet)
    }
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      // A file keeps its real name: the display name can drop the extension, which sets its category.
      let size = Self.allocatedSize(values)
      record(files: 1, bytes: size, path: url.path)
      return FileNode(name: url.lastPathComponent, url: url, size: size)
    }
    let name = FileManager.default.displayName(atPath: url.path)
    // `/` is a volume root, and so is a folder on another device than its parent. When either
    // device cannot be read, the folder is not taken for a volume root.
    let device = Self.device(of: url.path)
    let parentDevice = Self.device(of: url.deletingLastPathComponent().path)
    let isVolumeRoot =
      url.path == "/" || (device != nil && parentDevice != nil && parentDevice != device)
    return try await scanDirectory(
      url, name: name, isPackage: values.isPackage == true,
      isVolumeRoot: isVolumeRoot, depth: 0, previewParent: nil)
  }

  private static func device(of path: String) -> Int32? {
    var info = stat()
    return stat(path, &info) == 0 ? info.st_dev : nil
  }

  /// Sends the last progress event. Its preview includes every update, even ones that came in
  /// less than `previewInterval` after the previous rebuild.
  func emitFinal(path: String) {
    _ = counters.withLock { state in
      if state.previewChanged {
        state.snapshot = state.previewRoot.flatMap { Self.snapshot(of: $0, in: state) }
        state.previewChanged = false
      }
      return progress?.yield(
        ScanProgress(
          filesScanned: state.files, bytesScanned: state.bytes, currentPath: path,
          preview: state.snapshot))
    }
  }

  /// Scans one folder. `isVolumeRoot` tells whether it is a volume root (see
  /// `DiskScanner.skipsFolder`). `previewParent` is the path of the preview folder this folder
  /// reports to: its parent when `depth <= previewDepth` (nil for the root), otherwise the
  /// `previewDepth` folder it lies in.
  private func scanDirectory(
    _ url: URL, name: String, isPackage: Bool, isVolumeRoot: Bool, depth: Int,
    previewParent: String?
  ) async throws -> FileNode {
    try Task.checkCancellation()
    guard let entries = DirectoryReader.entries(atPath: url.path) else {
      if depth <= Self.previewDepth {
        let folder = PreviewFolder(name: name, url: url, isPackage: isPackage, accessDenied: true)
        record(files: 0, bytes: 0, path: url.path, preview: .folder(folder, parent: previewParent))
      }
      return FileNode(
        name: name, url: url, children: [], isPackage: isPackage, accessDenied: true)
    }

    var children: [FileNode] = []
    var subfolders: [(url: URL, isPackage: Bool)] = []
    var files = 0
    var bytes: Int64 = 0
    for entry in entries {
      switch entry.kind {
      case .symbolicLink:
        continue
      case .directory:
        // Do not cross into another volume, or walk the root mirrors (see `skipsFolder`).
        if DiskScanner.skipsFolder(entry, parentIsVolumeRoot: isVolumeRoot) { continue }
        let folder = url.appendingPathComponent(entry.name, isDirectory: true)
        subfolders.append((folder, Self.isPackage(path: folder.path)))
      case .file:
        if entry.linkCount > 1,
          !isFirstSighting(of: FileID(device: entry.device, inode: entry.inode))
        {
          continue
        }
        var size = entry.countedSize
        // Clones whose original is gone share blocks that none of them reports as private: the
        // first one seen counts its whole allocation, the others only their own bytes.
        if entry.isOrphanedClone, let id = entry.cloneID,
          isFirstSighting(of: FileID(device: entry.device, inode: id))
        {
          size = entry.allocatedSize
        }
        let file = url.appendingPathComponent(entry.name, isDirectory: false)
        children.append(FileNode(name: entry.name, url: file, size: size))
        files += 1
        bytes += size
      }
    }
    record(
      files: files, bytes: bytes, path: url.path,
      preview: previewUpdate(
        url: url, name: name, isPackage: isPackage, files: children, depth: depth,
        previewParent: previewParent))

    let childPreviewParent = depth <= Self.previewDepth ? url.path : previewParent
    children += try await scanSubfolders(
      subfolders, depth: depth + 1, previewParent: childPreviewParent)
    return FileNode(name: name, url: url, children: children, isPackage: isPackage)
  }

  /// Scans `folders`, giving each its own task while the scan is under `maxConcurrency` tasks
  /// and scanning the rest in this task. Work spreads over the whole tree this way, not only
  /// near the root, and the number of tasks stays bounded. Subfolders are never volume roots.
  private func scanSubfolders(
    _ folders: [(url: URL, isPackage: Bool)], depth: Int, previewParent: String?
  ) async throws -> [FileNode] {
    func scan(_ folder: (url: URL, isPackage: Bool)) async throws -> FileNode {
      try await scanDirectory(
        folder.url, name: folder.url.lastPathComponent, isPackage: folder.isPackage,
        isVolumeRoot: false, depth: depth, previewParent: previewParent)
    }
    guard folders.count > 1 else { return try await folders.asyncMap(scan) }
    return try await withThrowingTaskGroup(of: FileNode.self) { group in
      var results: [FileNode] = []
      results.reserveCapacity(folders.count)
      for folder in folders {
        if reserveTask() {
          group.addTask {
            defer { self.activeTasks.subtract(1, ordering: .releasing) }
            return try await scan(folder)
          }
        } else {
          results.append(try await scan(folder))
        }
      }
      while let node = try await group.next() {
        results.append(node)
      }
      return results
    }
  }

  /// Takes a task slot when one is free.
  private func reserveTask() -> Bool {
    var current = activeTasks.load(ordering: .relaxed)
    while current < maxConcurrency {
      let (exchanged, original) = activeTasks.compareExchange(
        expected: current, desired: current + 1, ordering: .acquiringAndReleasing)
      if exchanged { return true }
      current = original
    }
    return false
  }

  /// Returns true the first time an identity is seen during this scan: a hard-linked inode or an
  /// orphaned-clone group.
  private func isFirstSighting(of id: FileID) -> Bool {
    counters.withLock { $0.seenIdentities.insert(id).inserted }
  }

  /// Only folders with an extension (such as `.app`) can be packages, so skip the lookup for
  /// the rest. The lookup uses a temporary URL: resource values cached on it die with it, while
  /// a URL a node keeps would hold them for the life of the tree.
  private static func isPackage(path: String) -> Bool {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    guard !url.pathExtension.isEmpty else { return false }
    return (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
  }

  /// What a scanned folder reports to the preview tree. `files` are its direct files.
  private func previewUpdate(
    url: URL, name: String, isPackage: Bool, files: [FileNode], depth: Int,
    previewParent: String?
  ) -> PreviewUpdate {
    guard progress != nil else { return .none }
    let bytes = files.reduce(Int64(0)) { $0 + $1.size }
    guard depth <= Self.previewDepth else {
      guard let previewParent, bytes > 0 else { return .none }
      return .bytes(bytes, into: previewParent)
    }
    var folder = PreviewFolder(name: name, url: url, isPackage: isPackage, accessDenied: false)
    if depth < Self.previewDepth {
      let largest = files.sorted(by: FileNode.largerFirst).prefix(Self.previewFileLimit)
      folder.files = largest.map { ($0.name, $0.url, $0.size) }
      folder.otherBytes = bytes - largest.reduce(Int64(0)) { $0 + $1.size }
    } else {
      folder.otherBytes = bytes
    }
    return .folder(folder, parent: previewParent)
  }

  private func record(
    files: Int, bytes: Int64, path: String, preview update: PreviewUpdate = .none
  ) {
    // Yielding under the lock keeps events in order when folders are scanned in parallel.
    counters.withLock { state in
      // Read the clock under the lock, so `now` is never earlier than `lastPreview`. Otherwise
      // the last preview update could be skipped and the final preview would be stale.
      let now = clock.now
      state.files += files
      state.bytes += bytes
      Self.apply(update, to: &state)
      if state.previewChanged,
        state.lastPreview.map({ now - $0 >= previewInterval }) ?? true
      {
        state.snapshot = state.previewRoot.flatMap { Self.snapshot(of: $0, in: state) }
        state.previewChanged = false
        state.lastPreview = now
      }
      if let last = state.lastEmit, now - last < progressInterval { return }
      state.lastEmit = now
      progress?.yield(
        ScanProgress(
          filesScanned: state.files, bytesScanned: state.bytes, currentPath: path,
          preview: state.snapshot))
    }
  }

  private static func apply(_ update: PreviewUpdate, to state: inout Counters) {
    switch update {
    case .none:
      return
    case .folder(let folder, let parent):
      let path = folder.url.path
      state.previewFolders[path] = folder
      if let parent {
        state.previewFolders[parent]?.subfolders.append(path)
      } else {
        state.previewRoot = path
      }
    case .bytes(let bytes, let path):
      state.previewFolders[path]?.otherBytes += bytes
    }
    state.previewChanged = true
  }

  /// Builds a fresh `FileNode` tree from the preview folder at `path` down.
  ///
  /// This runs under the counters lock, so other scan tasks wait while it works (it also
  /// categorizes each listed file for the folder stats). That is accepted: the preview holds
  /// at most two folder levels and `previewFileLimit` files per folder, and it is rebuilt at
  /// most once per `previewInterval`. Building it outside the lock would need copies of the
  /// preview state and extra ordering to keep the newest snapshot.
  private static func snapshot(of path: String, in state: Counters) -> FileNode? {
    guard let folder = state.previewFolders[path] else { return nil }
    var children = folder.files.map { FileNode(name: $0.name, url: $0.url, size: $0.size) }
    children += folder.subfolders.compactMap { snapshot(of: $0, in: state) }
    let size = children.reduce(folder.otherBytes) { $0 + $1.size }
    return FileNode(
      name: folder.name, url: folder.url, children: children, size: size,
      isPackage: folder.isPackage, accessDenied: folder.accessDenied)
  }

  private static func allocatedSize(_ values: URLResourceValues) -> Int64 {
    Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
  }
}

extension Array {
  fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var results: [T] = []
    results.reserveCapacity(count)
    for element in self { results.append(try await transform(element)) }
    return results
  }
}
