import Foundation

/// The folders and volumes scanned most recently, newest first, kept in `UserDefaults`.
public struct RecentScans {
  public static let defaultsKey = "recentScans"
  public let limit: Int
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard, limit: Int = 8) {
    self.defaults = defaults
    self.limit = limit
  }

  public var urls: [URL] {
    (defaults.stringArray(forKey: Self.defaultsKey) ?? []).map { URL(fileURLWithPath: $0) }
  }

  /// Puts `url` at the front, dropping an older entry for the same path and the oldest entries
  /// beyond `limit`. Returns the updated list.
  @discardableResult
  public func add(_ url: URL) -> [URL] {
    let path = url.standardizedFileURL.path
    var paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    paths.removeAll { $0 == path }
    paths.insert(path, at: 0)
    paths = Array(paths.prefix(limit))
    defaults.set(paths, forKey: Self.defaultsKey)
    return paths.map { URL(fileURLWithPath: $0) }
  }

  public func clear() {
    defaults.removeObject(forKey: Self.defaultsKey)
  }
}
