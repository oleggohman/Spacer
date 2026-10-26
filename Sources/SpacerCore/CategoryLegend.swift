import Foundation

/// One chip of the map legend: a category and how much of a folder it takes up.
public struct CategoryShare: Sendable, Equatable, Identifiable {
  public let category: FileCategory
  public let bytes: Int64
  /// `bytes` as a part of the folder's size, 0...1.
  let fraction: Double

  public var id: FileCategory { category }

  /// False when the folder holds none of the category: highlighting it would only fade the
  /// whole map, so the legend disables its chip.
  public var canHighlight: Bool { bytes > 0 }

  /// The share as a short percentage: "42%", "<1%" for a tiny non-zero share, "" for none.
  public var percentText: String { Self.percentText(bytes: bytes, fraction: fraction) }

  static func percentText(bytes: Int64, fraction: Double) -> String {
    guard bytes > 0 else { return "" }
    let percent = (fraction * 100).rounded()
    return percent < 1 ? "<1%" : "\(Int(percent))%"
  }
}

/// What the legend under the map shows for a folder.
public struct CategoryLegend: Sendable, Equatable {
  /// The categories with a chip, in legend order. Folders have no chip: they are drawn neutral.
  static let categories: [FileCategory] = FileCategory.allCases.filter { $0 != .folders }

  /// One share per legend category, in legend order, including empty ones.
  public let shares: [CategoryShare]
  /// Bytes of the folder that no listed file accounts for, such as content a scan preview has
  /// not listed yet. The shares plus this add up to the folder's size.
  public let unlisted: Int64
  /// The folder's size, kept to work out `unlistedPercentText`.
  private let size: Int64

  /// The legend for `node`, usually the zoom focus or the scan preview.
  public init(for node: FileNode) {
    let stats = node.categoryStats
    let size = node.size
    self.size = size
    shares = Self.categories.map { category in
      let bytes = stats[category]
      let fraction = size > 0 ? Double(bytes) / Double(size) : 0
      return CategoryShare(category: category, bytes: bytes, fraction: fraction)
    }
    unlisted = max(0, size - shares.reduce(0) { $0 + $1.bytes })
  }

  /// `unlisted` as a short percentage, "" when every byte is listed.
  public var unlistedPercentText: String {
    let fraction = size > 0 ? Double(unlisted) / Double(size) : 0
    return CategoryShare.percentText(bytes: unlisted, fraction: fraction)
  }
}

/// Emphasis for one category picked in the legend: matching blocks keep their color and the
/// rest of the map fades.
///
/// What stays bright follows what the legend of the map's root counts under the chip. Inside an
/// app bundle below the root, everything counts as apps (the root's legend counts the bundle's
/// whole size as apps), so all of it matches `.apps` and nothing else. Elsewhere, and inside a
/// bundle that is itself the root, items match by their own content.
public enum CategoryHighlight {
  /// How far a faded block moves toward the map background.
  public static let fadeAmount = 0.7
  /// The opacity of a header's text when its folder holds none of the highlighted category.
  public static let dimmedHeaderOpacity = 0.45

  /// True when `rect` of a map laid out from `root` stays bright while `category` is
  /// highlighted. Outside app bundles, a block matches its `colorCategory` (a file its own
  /// category, a plain folder its dominant one), a "small items" block matches its parent's
  /// dominant category (it is drawn neutral, so this only decides the fade), and a header matches when its folder holds
  /// any bytes of `category`, so the path to a match stays readable.
  public static func matches(_ rect: TreemapRect, category: FileCategory, root: FileNode) -> Bool {
    let node = rect.node
    if isInsideAppBundle(node, below: root) { return category == .apps }
    switch rect.kind {
    case .block: return node.colorCategory == category
    case .folderHeader: return node.categoryStats[category] > 0
    case .smallItems: return node.dominantCategory == category
    }
  }

  /// True when `node` is an app bundle below `root` or lies inside one.
  static func isInsideAppBundle(_ node: FileNode, below root: FileNode) -> Bool {
    var current: FileNode? = node
    while let item = current, item !== root {
      if item.isAppBundle { return true }
      current = item.parent
    }
    return false
  }

  /// The text color and opacity of a folder header drawn with `fill` (its folder block's
  /// unfaded fill). The header sits on its folder's block, so the color is the label color of
  /// that block as shown (faded or not); the text is dimmed when the header itself does not
  /// match the highlight.
  public static func headerText(
    _ rect: TreemapRect, fill: RGBColor, highlight: FileCategory?, root: FileNode,
    darkMode: Bool
  ) -> (color: RGBColor, opacity: Double) {
    guard let highlight else { return (fill.labelColor, 1) }
    let block = TreemapRect(node: rect.node, rect: rect.rect, depth: rect.depth, kind: .block)
    let blockFill = shown(fill, for: block, highlight: highlight, root: root, darkMode: darkMode)
    let opacity = matches(rect, category: highlight, root: root) ? 1 : dimmedHeaderOpacity
    return (blockFill.color.labelColor, opacity)
  }

  /// How a block or "small items" `rect` with `fill` is drawn: its fill, or the fill faded
  /// toward the background when `highlight` is set and `rect` does not match it. `faded` tells
  /// the view to dim the block's label too.
  public static func shown(
    _ fill: RGBColor, for rect: TreemapRect, highlight: FileCategory?, root: FileNode,
    darkMode: Bool
  ) -> (color: RGBColor, faded: Bool) {
    guard let highlight, !matches(rect, category: highlight, root: root) else {
      return (fill, false)
    }
    return (faded(fill, darkMode: darkMode), true)
  }

  /// The map background faded blocks move toward (see `MapPalette.background`).
  public static func background(darkMode: Bool) -> RGBColor {
    MapPalette.background(darkMode: darkMode)
  }

  /// `color` faded toward the map background.
  public static func faded(_ color: RGBColor, darkMode: Bool) -> RGBColor {
    color.mixed(with: background(darkMode: darkMode), by: fadeAmount)
  }
}
