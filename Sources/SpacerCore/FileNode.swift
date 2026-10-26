import Foundation

/// One file or folder in a scanned tree.
///
/// Nodes are built bottom-up by `DiskScanner` and are not mutated concurrently afterwards,
/// which is why the class is marked `@unchecked Sendable`. Later mutations (such as removing
/// a deleted node) must happen on a single actor.
public final class FileNode: @unchecked Sendable, Identifiable {
  public let name: String
  /// The path, kept only while the node has no parent: the root's, and a removed node's (see
  /// `url`). Attached nodes drop it, so a scan's nodes do not each hold a full-path URL.
  private var storedURL: URL?
  public let isDirectory: Bool
  /// True for bundles such as `.app` folders. They are scanned like ordinary folders.
  public let isPackage: Bool
  /// True when the folder could not be read. Its size then only reflects what was readable (nothing).
  public let accessDenied: Bool
  /// Allocated bytes on disk. For a folder this is the sum of its children.
  public internal(set) var size: Int64
  /// Number of items in this subtree, counting the node itself.
  public internal(set) var itemCount: Int
  /// Children sorted by size, largest first. Empty for files.
  public internal(set) var children: [FileNode]
  public internal(set) weak var parent: FileNode?
  /// True for an application bundle (a `.app`, `.appex` or `.prefpane` package). It is drawn
  /// as an app and counts as app bytes in its parent, but its own stats show its real content.
  public let isAppBundle: Bool
  /// What a folder's children add up to (see `categoryStats`), boxed so that files and empty
  /// folders do not each carry the category bytes. Nil until a folder has content.
  private var folderBox: FolderStats?

  public var id: ObjectIdentifier { ObjectIdentifier(self) }

  /// The full path. A node in a tree builds it from its parent, so only the root (and a removed
  /// node, see `remove()`) stores one. If the root has been released, the path is unknown: the
  /// result is then not a file URL (`detached:<name>`), so it can never name a real file, and
  /// `DeletionService` refuses it.
  public var url: URL {
    if let storedURL { return storedURL }
    guard let parent else { return URL(string: "detached:")!.appendingPathComponent(name) }
    return parent.url.appendingPathComponent(name, isDirectory: isDirectory)
  }

  /// The folder stats, read and written as a value. Writing zero stats to a folder without a box
  /// allocates nothing.
  private var folderStats: CategoryStats {
    get { folderBox?.value ?? CategoryStats() }
    set {
      if let folderBox {
        folderBox.value = newValue
      } else if newValue != CategoryStats() {
        folderBox = FolderStats(value: newValue)
      }
    }
  }

  /// Creates a file node with a known allocated size.
  public init(name: String, url: URL, size: Int64) {
    self.name = name
    self.storedURL = url
    self.isDirectory = false
    self.isPackage = false
    self.isAppBundle = false
    self.accessDenied = false
    self.size = size
    self.itemCount = 1
    self.children = []
  }

  /// Creates a folder node. Its size and item count are derived from the children.
  public init(
    name: String, url: URL, children: [FileNode], isPackage: Bool = false,
    accessDenied: Bool = false
  ) {
    self.name = name
    self.storedURL = url
    self.isDirectory = true
    self.isPackage = isPackage
    self.isAppBundle = FileCategory.isAppBundle(url: url, isPackage: isPackage)
    self.accessDenied = accessDenied
    self.children = children.sorted(by: FileNode.largerFirst)
    self.size = children.reduce(0) { $0 + $1.size }
    self.itemCount = children.reduce(1) { $0 + $1.itemCount }
    for child in self.children {
      child.parent = self
      // The child's path now comes from its parent, so it stops keeping its own.
      child.storedURL = nil
      if !child.isDirectory {
        folderStats[FileCategory.of(child)] += child.size
      } else if child.isAppBundle {
        folderStats[.apps] += child.size
      } else {
        folderStats.add(child.folderStats)
      }
    }
  }

  /// Creates a folder node whose size is given rather than derived, so it can include bytes
  /// that `children` do not show. Used for the scan preview, whose folders summarise content
  /// that is not listed.
  convenience init(
    name: String, url: URL, children: [FileNode], size: Int64, isPackage: Bool = false,
    accessDenied: Bool = false
  ) {
    self.init(
      name: name, url: url, children: children, isPackage: isPackage, accessDenied: accessDenied)
    self.size = size
  }

  /// Bytes per category in this subtree. A file has its own size under its category. A folder
  /// (an app bundle too) sums what its children add: a file its size under its category, an
  /// app bundle its whole size under `.apps`, and a plain folder its own stats. So
  /// /Applications reads as apps, while zooming into Xcode.app shows what it is made of. Kept
  /// up to date by `remove()`.
  public var categoryStats: CategoryStats {
    isDirectory ? folderStats : CategoryStats(FileCategory.of(self), bytes: size)
  }

  /// The category stats of a folder, boxed (see `folderBox`).
  private final class FolderStats {
    var value: CategoryStats
    init(value: CategoryStats) { self.value = value }
  }

  /// What this node adds to its parent's `categoryStats`.
  private var statsInParent: CategoryStats {
    isAppBundle ? CategoryStats(.apps, bytes: size) : categoryStats
  }

  /// The category holding the most bytes in this subtree, or nil when it has none.
  public var dominantCategory: FileCategory? { categoryStats.dominant }

  /// The category a file or app bundle block is colored by. For a plain folder (drawn neutral) it
  /// is its dominant category, or `.folders` when it has none, which the highlight matches on.
  public var colorCategory: FileCategory {
    let own = FileCategory.of(self)
    return own == .folders ? dominantCategory ?? .folders : own
  }

  /// Path components from the root of the tree down to this node, inclusive.
  public var ancestry: [FileNode] {
    var chain: [FileNode] = [self]
    var current = parent
    while let node = current {
      chain.append(node)
      current = node.parent
    }
    return chain.reversed()
  }

  /// Detaches the node from its parent and subtracts its size, item count and category bytes
  /// from every ancestor. Ancestors stay sorted by size within their own parents.
  public func remove() {
    guard let parent else { return }
    // Keep the path for callers that still use the node (deletion results, alerts).
    storedURL = url
    parent.children.removeAll { $0 === self }
    self.parent = nil
    var stats = statsInParent
    var current: FileNode? = parent
    while let node = current {
      node.size -= size
      node.itemCount -= itemCount
      node.folderStats.subtract(stats)
      // An app bundle adds its whole size as app bytes to its parent, so from there up the
      // removed bytes were counted as app bytes.
      if node.isAppBundle { stats = CategoryStats(.apps, bytes: size) }
      node.parent?.children.sort(by: FileNode.largerFirst)
      current = node.parent
    }
  }

  /// Puts a removed node back under this folder, the inverse of `remove()`. Its size, item count
  /// and category bytes are added to this folder and every ancestor, and the sort order is kept.
  public func attach(_ child: FileNode) {
    precondition(child.parent == nil && isDirectory, "attach needs a removed node and a folder")
    child.parent = self
    child.storedURL = nil
    children.append(child)
    children.sort(by: FileNode.largerFirst)
    var stats = child.statsInParent
    var current: FileNode? = self
    while let node = current {
      node.size += child.size
      node.itemCount += child.itemCount
      node.folderStats.add(stats)
      if node.isAppBundle { stats = CategoryStats(.apps, bytes: child.size) }
      node.parent?.children.sort(by: FileNode.largerFirst)
      current = node.parent
    }
  }

  /// True when `other` is this node or one of its descendants.
  public func contains(_ other: FileNode) -> Bool {
    var current: FileNode? = other
    while let node = current {
      if node === self { return true }
      current = node.parent
    }
    return false
  }

  /// Every unreadable folder in this subtree, this node included, depth-first. The walk does not
  /// go inside an unreadable folder, since it has no children.
  public func unreadableFolders() -> [FileNode] {
    var found: [FileNode] = []
    collectUnreadableFolders(into: &found)
    return found
  }

  private func collectUnreadableFolders(into found: inout [FileNode]) {
    if accessDenied {
      found.append(self)
      return
    }
    for child in children { child.collectUnreadableFolders(into: &found) }
  }

  static func largerFirst(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
    if lhs.size != rhs.size { return lhs.size > rhs.size }
    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
  }
}

extension FileNode: Hashable {
  public static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}
