import Foundation

/// Bytes per file category in a subtree. Folders hold the sum of what their children add (see
/// `FileNode.categoryStats`), so the legend and the category highlight can tell what a folder holds.
///
/// Only bytes that are listed as files (or app bundles) count. A scan preview folder whose size
/// includes unlisted content shows just its listed items here, and a folder with nothing listed
/// has no dominant category.
public struct CategoryStats: Sendable, Equatable {
  private typealias Bytes = (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64)

  /// Bytes indexed by `FileCategory.index`, stored inline (one `Int64` per category), so the
  /// value type needs no heap storage; `FileNode` boxes it only for folders with content.
  /// Zero everywhere when nothing is counted.
  private var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0)

  public init() {}

  /// Stats with `size` bytes in one category.
  public init(_ category: FileCategory, bytes size: Int64) {
    self[category] = size
  }

  public subscript(category: FileCategory) -> Int64 {
    get {
      let offset = Self.offset(of: category)
      return withUnsafeBytes(of: bytes) { $0.load(fromByteOffset: offset, as: Int64.self) }
    }
    set {
      let offset = Self.offset(of: category)
      withUnsafeMutableBytes(of: &bytes) {
        $0.storeBytes(of: newValue, toByteOffset: offset, as: Int64.self)
      }
    }
  }

  /// The byte offset of `category` in `bytes`. The tuple holds one `Int64` per category, so the
  /// category count must stay at nine (a test checks the layout too). Checked in debug builds
  /// only, as this runs for every category access of a scan.
  private static func offset(of category: FileCategory) -> Int {
    assert(FileCategory.count == MemoryLayout<Bytes>.size / MemoryLayout<Int64>.stride)
    return category.index * MemoryLayout<Int64>.stride
  }

  /// The sum over all categories.
  var total: Int64 { FileCategory.ordered.reduce(0) { $0 + self[$1] } }

  /// The category with the most bytes, or nil when there are none. Ties go to the category
  /// that comes first in `FileCategory.allCases`, so the winner is stable.
  public var dominant: FileCategory? {
    var best: FileCategory?
    var bestBytes: Int64 = 0
    for category in FileCategory.ordered where self[category] > bestBytes {
      best = category
      bestBytes = self[category]
    }
    return best
  }

  public mutating func add(_ other: CategoryStats) {
    for category in FileCategory.ordered { self[category] += other[category] }
  }

  public mutating func subtract(_ other: CategoryStats) {
    for category in FileCategory.ordered { self[category] -= other[category] }
  }

  public static func == (lhs: CategoryStats, rhs: CategoryStats) -> Bool {
    FileCategory.ordered.allSatisfy { lhs[$0] == rhs[$0] }
  }
}
