import Foundation

/// The folders under a scan that could not be read. Their sizes are not known, so the map
/// shows them without a size; the summary warns about them and the list shows where they are.
public struct UnreadableFolders: Sendable {
  /// The folders, sorted by path.
  public let nodes: [FileNode]

  public init(_ nodes: [FileNode]) {
    // Paths are built once, not inside the comparator.
    self.nodes = nodes.map { (path: $0.url.path, node: $0) }
      .sorted { $0.path < $1.path }.map(\.node)
  }

  /// The folders left after nodes in the subtrees of `removed` are gone.
  public func removing(under removed: [FileNode]) -> UnreadableFolders {
    guard !removed.isEmpty else { return self }
    return UnreadableFolders(nodes.filter { node in !removed.contains { $0.contains(node) } })
  }

  /// The folders plus `added`, for items put back into the tree.
  public func adding(_ added: [FileNode]) -> UnreadableFolders {
    added.isEmpty ? self : UnreadableFolders(nodes + added)
  }

  public var count: Int { nodes.count }

  /// The first `limit` folders in path order.
  public func shown(limit: Int = 20) -> [FileNode] {
    Array(nodes.prefix(limit))
  }

  /// How many folders `shown(limit:)` leaves out.
  public func hiddenCount(limit: Int = 20) -> Int {
    max(0, nodes.count - limit)
  }

  /// How many unreadable folders are `node` itself or below it.
  public func countUnder(_ node: FileNode) -> Int {
    nodes.reduce(0) { $0 + (node.contains($1) ? 1 : 0) }
  }

  /// The warning line for the summary. A scan root that could not be read gets its own text. With
  /// Full Disk Access granted, the folders are protected by macOS, so the text says so instead.
  public static func warningText(count: Int, rootDenied: Bool, hasFullDiskAccess: Bool) -> String {
    if rootDenied {
      return hasFullDiskAccess
        ? "Spacer couldn't read this location. macOS protects it."
        : "Spacer couldn't read this location. Grant Full Disk Access and rescan."
    }
    let noun = count == 1 ? "folder" : "folders"
    guard hasFullDiskAccess else {
      return "\(count.formatted()) \(noun) couldn't be read. Grant Full Disk Access"
    }
    let protection =
      count == 1
      ? "macOS protects it, so its size isn't counted."
      : "macOS protects them, so their size isn't counted."
    return "\(count.formatted()) \(noun) couldn't be read. \(protection)"
  }

  /// The line under a folder in the inspector that holds unreadable folders.
  public static func includesText(count: Int) -> String {
    let noun = count == 1 ? "folder" : "folders"
    return "Includes \(count.formatted()) \(noun) Spacer couldn't read"
  }

  /// The last line of the list popover, for the folders it leaves out.
  public static func moreText(hidden: Int) -> String {
    "and \(hidden.formatted()) more"
  }
}
