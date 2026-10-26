import Foundation

/// Facts about a file or folder shown in the inspector that the scan does not record.
public struct ItemDetails: Sendable, Equatable {
  public let kind: String
  public let modified: Date?

  public init(kind: String, modified: Date?) {
    self.kind = kind
    self.modified = modified
  }

  /// Reads the localized kind and modification date of `node` from disk.
  public static func load(for node: FileNode) -> ItemDetails {
    let values = try? node.url.resourceValues(forKeys: [
      .localizedTypeDescriptionKey, .contentModificationDateKey,
    ])
    let fallback = node.isDirectory ? "Folder" : "File"
    return ItemDetails(
      kind: values?.localizedTypeDescription ?? fallback,
      modified: values?.contentModificationDate)
  }
}

extension FileNode {
  /// The largest `limit` children. Children are already sorted by size.
  public func largestChildren(_ limit: Int = 10) -> [FileNode] {
    Array(children.prefix(max(0, limit)))
  }

  /// True when this node's name contains `query` (case and diacritic insensitive,
  /// surrounding whitespace ignored). An empty query matches nothing.
  public func nameMatches(_ query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return false }
    return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }
}

/// The tiny children of a folder that the map merges into one "N small items" block. It stands
/// for several items, so the inspector shows it read-only and file actions never target it.
public struct SmallItemsGroup: Sendable {
  /// The folder that holds the merged items.
  public let parent: FileNode
  public let count: Int
  public let size: Int64

  public init(parent: FileNode, count: Int, size: Int64) {
    self.parent = parent
    self.count = count
    self.size = size
  }

  /// The group for a small-items rect, or nil for any other kind of rect.
  public init?(rect: TreemapRect) {
    guard case .smallItems(let count, let size) = rect.kind else { return nil }
    self.init(parent: rect.node, count: count, size: size)
  }

  /// The merged children: the last `count` non-empty children of `parent`. Children are sorted
  /// largest first and the layout skips empty ones, so these are the smallest.
  public var members: [FileNode] {
    Array(parent.children.filter { $0.size > 0 }.suffix(count))
  }

  /// The members' largest `limit` items, largest first.
  public func largest(_ limit: Int = 20) -> [FileNode] {
    Array(members.prefix(max(0, limit)))
  }

  /// "24,209 small items".
  public var title: String { "\(count.formatted()) small items" }

  /// "in node_modules", the folder that holds them.
  public var subtitle: String { "in \(parent.name)" }
}

/// Where the user grants Full Disk Access.
public enum FullDiskAccess {
  public static let settingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

  /// Files that only Full Disk Access can open, so the probe needs no other permission.
  public static var defaultProbePaths: [String] {
    [
      "/Library/Application Support/com.apple.TCC/TCC.db",
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Safari/Bookmarks.plist").path,
    ]
  }

  /// True when the app can open a TCC-protected file, which means it has Full Disk Access. The
  /// first path that can be opened or is refused decides. Paths that do not exist are skipped.
  /// False when no path decides, which keeps the suggestion to grant access.
  public static func isGranted(probePaths: [String] = defaultProbePaths) -> Bool {
    for path in probePaths {
      let fd = open(path, O_RDONLY)
      if fd >= 0 {
        close(fd)
        return true
      }
      if errno == EPERM || errno == EACCES { return false }
    }
    return false
  }
}

extension VolumeInfo {
  /// "380 GB used · 120 GB free", the sidebar's second line.
  public var usedAndFreeText: String {
    "\(ByteFormat.string(usedCapacity)) used · \(ByteFormat.string(availableCapacity)) free"
  }
}
