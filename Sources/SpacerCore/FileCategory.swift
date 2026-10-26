import Foundation
import Synchronization
import UniformTypeIdentifiers

/// An sRGB color with components in 0...1. The app converts it to a SwiftUI `Color`.
public struct RGBColor: Sendable, Equatable {
  public var red: Double
  public var green: Double
  public var blue: Double

  public init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// Converts hue, saturation and brightness (all 0...1) to RGB.
  public init(hue: Double, saturation: Double, brightness: Double) {
    let h = (hue - hue.rounded(.down)) * 6
    let s = min(max(saturation, 0), 1)
    let v = min(max(brightness, 0), 1)
    let sector = Int(h) % 6
    let f = h - Double(Int(h))
    let p = v * (1 - s)
    let q = v * (1 - s * f)
    let t = v * (1 - s * (1 - f))
    switch sector {
    case 0: (red, green, blue) = (v, t, p)
    case 1: (red, green, blue) = (q, v, p)
    case 2: (red, green, blue) = (p, v, t)
    case 3: (red, green, blue) = (p, q, v)
    case 4: (red, green, blue) = (t, p, v)
    default: (red, green, blue) = (v, p, q)
    }
  }
}

/// The kind of a file, used to color its block in the treemap.
public enum FileCategory: String, Sendable, CaseIterable {
  case video
  case audio
  case images
  case documents
  case code
  case archives
  case apps
  case other
  case folders

  /// The name shown in the legend. Images, audio and code have names people use instead of
  /// their raw values; the rest are the raw value capitalized, such as "Video".
  public var displayName: String {
    switch self {
    case .images: "Photos"
    case .audio: "Music"
    case .code: "Developer"
    default: rawValue.capitalized
    }
  }

  /// All categories in `allCases` order, kept once so lookups by `index` do not rebuild it.
  static let ordered = FileCategory.allCases
  static let count = ordered.count
  /// Each category's position in `ordered`, worked out once from the case list.
  private static let positions = Dictionary(
    uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })

  /// The category's position in `allCases`, used to index `CategoryStats`.
  var index: Int { Self.positions[self]! }

  /// True for a package folder that is an application bundle, such as `Safari.app`.
  static func isAppBundle(url: URL, isPackage: Bool) -> Bool {
    isPackage && ["app", "appex", "prefpane"].contains(url.pathExtension.lowercased())
  }

  /// The category of a scanned node. Folders are `.folders`, except application bundles.
  public static func of(_ node: FileNode) -> FileCategory {
    if node.isDirectory { return node.isAppBundle ? .apps : .folders }
    return of(extension: (node.name as NSString).pathExtension)
  }

  /// The category for a file name extension (without the dot, any case).
  public static func of(extension ext: String) -> FileCategory {
    let ext = ext.lowercased()
    guard !ext.isEmpty else { return .other }
    if let known = byExtension[ext] { return known }
    if let cached = cachedSystemType(ext) { return cached }
    let category = ofSystemType(extension: ext)
    systemTypeCache.withLock { remember(category, for: ext, in: &$0) }
    return category
  }

  /// Categories already looked up through `UTType`, which is much slower than the table and
  /// runs for every file of a scan.
  private static let systemTypeCache = Mutex<[String: FileCategory]>([:])
  static let systemTypeCacheLimit = 4096

  /// The category cached for `ext` (lowercased) by an earlier system type lookup.
  static func cachedSystemType(_ ext: String) -> FileCategory? {
    systemTypeCache.withLock { $0[ext] }
  }

  /// Adds a looked-up category to `cache` while it holds fewer than `limit` entries. Odd names
  /// such as "file.1a2b3c" would otherwise grow it without bound.
  static func remember(
    _ category: FileCategory, for ext: String, in cache: inout [String: FileCategory],
    limit: Int = systemTypeCacheLimit
  ) {
    if cache.count < limit { cache[ext] = category }
  }

  /// The category the system type of `ext` conforms to, without the table or the cache.
  static func ofSystemType(extension ext: String) -> FileCategory {
    guard let type = UTType(filenameExtension: ext) else { return .other }
    if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
    if type.conforms(to: .audio) { return .audio }
    if type.conforms(to: .image) { return .images }
    if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
    if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archives }
    if type.conforms(to: .application) || type.conforms(to: .executable) { return .apps }
    if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
      || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent)
    {
      return .documents
    }
    return .other
  }

  /// Extensions whose system type is missing or misleading (".ts" is MPEG-TS to the system).
  private static let byExtension: [String: FileCategory] = {
    var table: [String: FileCategory] = [:]
    let groups: [(FileCategory, [String])] = [
      (.video, ["mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg"]),
      (.audio, ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "caf"]),
      (
        .images,
        [
          "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "raw",
          "cr2", "nef", "dng", "psd", "svg",
        ]
      ),
      (
        .documents,
        [
          "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers",
          "key", "txt", "rtf", "md", "csv", "epub",
        ]
      ),
      (
        .code,
        [
          "swift", "c", "h", "m", "mm", "cpp", "hpp", "rs", "go", "py", "js", "ts", "tsx",
          "jsx", "java", "kt", "rb", "php", "sh", "zsh", "json", "yaml", "yml", "toml", "xml",
          "html", "css", "sql", "o", "a", "dylib",
        ]
      ),
      (
        .archives,
        [
          "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg",
          "zst",
        ]
      ),
      (.apps, ["app", "exe", "ipa", "apk"]),
    ]
    for (category, extensions) in groups {
      for ext in extensions { table[ext] = category }
    }
    return table
  }()

  /// The category's flat fill on the map, from Apple's Storage palette (see `MapPalette`).
  /// `.folders` gives the top-level folder fill; plain folders are drawn with `fill(for:)`.
  public func color(darkMode: Bool) -> RGBColor {
    switch self {
    case .documents: MapPalette.red(darkMode: darkMode)
    case .images: MapPalette.orange(darkMode: darkMode)
    case .audio: MapPalette.yellow(darkMode: darkMode)
    case .code: MapPalette.teal(darkMode: darkMode)
    case .apps: MapPalette.purple(darkMode: darkMode)
    case .video: MapPalette.pink(darkMode: darkMode)
    case .archives: MapPalette.green(darkMode: darkMode)
    case .other: MapPalette.gray(darkMode: darkMode)
    case .folders: MapPalette.folderFill(depth: 0, darkMode: darkMode)
    }
  }

  /// The fill of `node`'s block or header: a file takes its category color, an app bundle the
  /// apps color, and a plain folder the neutral folder fill for its depth.
  public static func fill(for node: FileNode, depth: Int, darkMode: Bool) -> RGBColor {
    let category = node.colorCategory
    guard node.isDirectory, !node.isAppBundle else {
      return category.color(darkMode: darkMode)
    }
    return MapPalette.folderFill(depth: depth, darkMode: darkMode)
  }
}
