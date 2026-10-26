import Foundation

/// How selected items are removed from disk.
public enum DeletionMode: Sendable, Equatable {
  case moveToTrash
  case deletePermanently
}

/// Why an item was not deleted.
public enum DeletionError: Error, Sendable, Equatable {
  case scanRoot
  case volumeRoot
  case homeFolder
  case systemPath
  case systemApp
  case outsideScanRoot
  case failed(String)
}

/// The outcome for one requested item. Deleting never throws for the whole batch.
public struct DeletionResult: Sendable {
  public let node: FileNode
  /// Nil on success.
  public let error: DeletionError?
  /// Where the item ended up when it was moved to the Trash.
  public let trashedURL: URL?

  public var succeeded: Bool { error == nil }
}

/// The items one Move to Trash put in the Trash, kept so the move can be undone. `parent` is the
/// folder each item was removed from, where it goes back to.
public struct TrashBatch: Sendable {
  public struct Item: Sendable {
    /// The removed node, detached from the tree.
    public let node: FileNode
    /// The folder the node was removed from.
    public let parent: FileNode
    /// Where the item is in the Trash.
    public let trashedURL: URL
  }

  /// The trashed items, one per item the user asked to remove (not the ones inside them).
  public let items: [Item]

  /// The combined size of the items.
  public var totalSize: Int64 { items.reduce(0) { $0 + $1.node.size } }

  /// "Moved “Name” to Trash · 4.2 GB" for one item, "Moved N items to Trash · 12.4 GB" for more.
  public var summaryText: String {
    DeletionSummary.text(of: items.map(\.node), phrase: DeletionSummary.trashedPhrase)
  }
}

/// The banner text after a delete, in one place for Move to Trash and permanent deletes.
public enum DeletionSummary {
  static func trashedPhrase(_ what: String) -> String { "Moved \(what) to Trash" }
  static func deletedPhrase(_ what: String) -> String { "Deleted \(what)" }

  /// "Deleted “Name” · 4.2 GB" or "Deleted N items · 12.4 GB", counting the items that were deleted
  /// and not the ones inside them. Nil when none was deleted.
  public static func deleted(results: [DeletionResult]) -> String? {
    summary(results: results, phrase: deletedPhrase)
  }

  /// "Moved “Name” to Trash · 4.2 GB" for a Move to Trash that cannot be undone, such as when the
  /// system gave no Trash location. Nil when nothing was moved.
  public static func trashed(results: [DeletionResult]) -> String? {
    summary(results: results, phrase: trashedPhrase)
  }

  private static func summary(
    results: [DeletionResult], phrase: (String) -> String
  ) -> String? {
    let done = ScanSession.topmost(Set(results.filter(\.succeeded).map(\.node)))
    return done.isEmpty ? nil : text(of: done, phrase: phrase)
  }

  /// `phrase` around "“Name”" for one node or "N items" for more, then " · size".
  static func text(of nodes: [FileNode], phrase: (String) -> String) -> String {
    let size = ByteFormat.string(nodes.reduce(0) { $0 + $1.size })
    if let only = nodes.first, nodes.count == 1 {
      return "\(phrase("“\(only.name)”")) · \(size)"
    }
    return "\(phrase("\(nodes.count.formatted()) items")) · \(size)"
  }
}

/// Moves items to the Trash or deletes them, after checking the guard rails.
///
/// The service only touches the filesystem. Callers update the tree with `FileNode.remove()`
/// for the items that succeeded.
public struct DeletionService: Sendable {
  /// System locations. Nothing in them may be deleted.
  public static let systemPrefixes = ["/System", "/usr", "/bin", "/sbin", "/Library"]
  /// Folders whose contents may be deleted, but not the folders themselves or their parents.
  /// They are what `/etc`, `/var` and `/tmp` point to.
  static let systemFolders = ["/private/etc", "/private/var", "/private/tmp"]

  public let root: URL
  public let homeDirectory: URL

  public init(
    root: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.root = root
    self.homeDirectory = homeDirectory
  }

  public func delete(nodes: [FileNode], mode: DeletionMode) async -> [DeletionResult] {
    perform(nodes, mode: mode)
  }

  /// Moves an item back from the Trash to `original`, the path it had before it was trashed.
  /// Returns nil on success. An item already at `original` is never overwritten.
  public func restore(trashedURL: URL, to original: URL) async -> DeletionError? {
    guard original.isFileURL, original.path.hasPrefix("/"),
      Self.isPath(Self.canonicalPath(original), under: Self.canonicalPath(root))
    else { return .outsideScanRoot }
    guard FileManager.default.fileExists(atPath: trashedURL.path) else {
      return .failed("The item is no longer in the Trash.")
    }
    guard !FileManager.default.fileExists(atPath: original.path) else {
      return .failed("An item with that name already exists.")
    }
    do {
      try FileManager.default.moveItem(at: trashedURL, to: original)
      return nil
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// Returns the reason `url` must not be deleted, or nil when it may be.
  ///
  /// A folder is also refused when it contains a protected location, because deleting it would
  /// delete that location too.
  public func refusal(for url: URL) -> DeletionError? {
    // A URL that is not an absolute file path (such as a node whose tree was released) would
    // resolve against the working directory.
    guard url.isFileURL, url.path.hasPrefix("/") else { return .outsideScanRoot }
    let path = Self.canonicalPath(url)
    let rootPath = Self.canonicalPath(root)
    if path == rootPath { return .scanRoot }
    if path == "/" || (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true {
      return .volumeRoot
    }
    if Self.isPath(Self.canonicalPath(homeDirectory), under: path) { return .homeFolder }
    let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? [])
      .map { Self.canonicalPath($0) }
    if volumes.contains(where: { $0 != "/" && Self.isPath($0, under: path) }) { return .volumeRoot }
    // Paths under /private may come out without the /private part, so check both forms.
    let containedFolders =
      Self.systemPrefixes + Self.systemFolders
      + Self.systemFolders.map { Self.canonicalPath(URL(fileURLWithPath: $0)) }
    if Self.systemPrefixes.contains(where: { Self.isPath(path, under: $0) })
      || containedFolders.contains(where: { Self.isPath($0, under: path) })
    {
      return .systemPath
    }
    if Self.isInsideSystemApp(path) || Self.isPath("/Applications", under: path)
      || (Self.isPath(path, under: "/Applications") && Self.containsSystemApp(path))
    {
      return .systemApp
    }
    if !Self.isPath(path, under: rootPath) { return .outsideScanRoot }
    return nil
  }

  private func perform(_ nodes: [FileNode], mode: DeletionMode) -> [DeletionResult] {
    var done: [FileNode] = []
    return nodes.map { node in
      // An item inside a folder that was already deleted in this batch is gone with it.
      if done.contains(where: { $0 !== node && $0.contains(node) }) {
        return DeletionResult(node: node, error: nil, trashedURL: nil)
      }
      if let reason = refusal(for: node.url) {
        return DeletionResult(node: node, error: reason, trashedURL: nil)
      }
      do {
        var trashedURL: URL?
        switch mode {
        case .moveToTrash:
          var resulting: NSURL?
          try FileManager.default.trashItem(at: node.url, resultingItemURL: &resulting)
          trashedURL = resulting as URL?
        case .deletePermanently:
          try FileManager.default.removeItem(at: node.url)
        }
        done.append(node)
        return DeletionResult(node: node, error: nil, trashedURL: trashedURL)
      } catch {
        return DeletionResult(
          node: node, error: .failed(error.localizedDescription), trashedURL: nil)
      }
    }
  }

  /// The absolute path with symlinks resolved in the parent folders only, so that a link is
  /// judged by where it sits rather than where it points.
  static func canonicalPath(_ url: URL) -> String {
    let standardized = url.standardizedFileURL
    let path = standardized.path
    guard path != "/" else { return path }
    let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath().path
    return (parent as NSString).appendingPathComponent(standardized.lastPathComponent)
  }

  static func isPath(_ path: String, under prefix: String) -> Bool {
    prefix == "/" || path == prefix || path.hasPrefix(prefix + "/")
  }

  /// True for an Apple app anywhere in /Applications (including subfolders such as Utilities),
  /// or anything inside one.
  static func isInsideSystemApp(_ path: String) -> Bool {
    let components = path.split(separator: "/")
    guard components.first == "Applications",
      let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") })
    else { return false }
    let appPath = "/" + components[...appIndex].joined(separator: "/")
    return isSystemApp(URL(fileURLWithPath: appPath))
  }

  /// True when the folder at `path` holds an Apple app at any depth, such as /Applications/Utilities.
  /// Paths inside an app bundle are left to `isInsideSystemApp`.
  static func containsSystemApp(_ path: String) -> Bool {
    guard !path.split(separator: "/").contains(where: { $0.hasSuffix(".app") }),
      let items = FileManager.default.enumerator(
        at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
        options: [.skipsPackageDescendants])
    else { return false }
    for case let item as URL in items where item.pathExtension == "app" {
      if isSystemApp(item) { return true }
    }
    return false
  }

  private static func isSystemApp(_ url: URL) -> Bool {
    Bundle(url: url)?.bundleIdentifier?.hasPrefix("com.apple.") == true
  }
}

extension DeletionError {
  /// A short explanation for the failure alert.
  public var message: String {
    switch self {
    case .scanRoot: "The scanned folder itself cannot be deleted."
    case .volumeRoot: "A volume root cannot be deleted."
    case .homeFolder: "Your home folder cannot be deleted."
    case .systemPath: "System locations are protected."
    case .systemApp: "System apps are protected."
    case .outsideScanRoot: "The item is outside the scanned folder."
    case .failed(let reason): reason
    }
  }
}
