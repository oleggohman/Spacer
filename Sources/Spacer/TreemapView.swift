import AppKit
import SpacerCore
import SwiftUI

/// The treemap of the zoom focus, drawn in a Canvas, with hover, selection, zoom and file actions.
struct TreemapView: View {
  let session: ScanSession
  let focus: FileNode
  let onDelete: (DeletionMode) -> Void
  /// False for the scan preview: only the tooltip works; nothing can be selected, zoomed or deleted.
  var interactive = true

  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var isFocused: Bool
  @State private var layout = CachedLayout()
  @State private var hoverLocation: CGPoint?
  /// VoiceOver children; recomputed only when the layout changes, never per frame.
  @State private var elements: [AccessibleBlock] = []

  private static let animationDuration: TimeInterval = 0.2
  /// Thin folder frames, so files take most of the visible area.
  private static let headerHeight: CGFloat = 14
  private static let framePadding: CGFloat = 1
  /// Space around the map; `mapPoint` removes it again for hit testing.
  private static let outerPadding: CGFloat = 8
  /// How far a block's fill is drawn inside its layout frame, and its corner radius.
  private static let blockInset: CGFloat = 1
  private static let blockCornerRadius: CGFloat = 3
  private static let searchOutlineWidth: CGFloat = 2
  private static let selectionOutlineWidth: CGFloat = 2.5
  private static let hoverOutlineWidth: CGFloat = 1

  var body: some View {
    GeometryReader { proxy in
      let key = LayoutKey(
        size: proxy.size, focus: ObjectIdentifier(focus), tree: session.treeVersion)
      // Read the highlight state here so that changes to it redraw the canvas.
      let marks = Highlights(
        selection: session.selection, hovered: session.hovered, query: session.searchQuery,
        category: session.highlightedCategory)
      TimelineView(.animation(paused: !layout.isAnimating(at: .now))) { timeline in
        Canvas { context, _ in
          draw(layout.frames(at: timeline.date), marks: marks, in: &context)
        }
      }
      .accessibilityLabel("Disk map of \(focus.name)")
      .accessibilityChildren { accessibilityElements }
      .onChange(of: key, initial: true) { old, new in
        let animate = old.size != new.size && old.focus == new.focus && !layout.rects.isEmpty
        layout.update(
          TreemapLayout.layout(
            root: focus, in: CGRect(origin: .zero, size: new.size), minSide: 6,
            headerHeight: Self.headerHeight, padding: Self.framePadding),
          animated: animate, duration: Self.animationDuration)
        elements =
          interactive ? TreemapNavigation.accessibleBlocks(in: layout.rects, focus: focus) : []
        if animate {
          // Redraw once the animation is over so the timeline pauses again.
          Task {
            try? await Task.sleep(for: .seconds(Self.animationDuration))
            layout.finishAnimation()
          }
        }
      }
    }
    .padding(Self.outerPadding)
    .overlay(alignment: .topLeading) {
      GeometryReader { proxy in tooltip(bounds: proxy.size) }.allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .onContinuousHover(coordinateSpace: .local) { phase in
      switch phase {
      case .active(let location):
        hoverLocation = location
        guard interactive else { return }
        let node = node(at: location)
        if session.hovered !== node { session.hovered = node }
      case .ended:
        hoverLocation = nil
        if interactive { session.hovered = nil }
      }
    }
    .gesture(SpatialTapGesture().onEnded { click(at: $0.location) })
    .contextMenu { contextMenu }
    .focusable()
    .focusEffectDisabled()
    .focused($isFocused)
    .onAppear { if interactive { isFocused = true } }
    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
      guard interactive else { return .ignored }
      return handleNavigation(press)
    }
    .onKeyPress(keys: [.escape, .delete]) { press in
      guard interactive else { return .ignored }
      if press.key == .delete, press.modifiers.contains(.command) {
        guard !session.selection.isEmpty else { return .ignored }
        onDelete(.moveToTrash)
        return .handled
      }
      guard session.canZoomOut else { return .ignored }
      session.zoomOut()
      return .handled
    }
  }

  // MARK: Interaction

  /// Arrow keys move the selection between sibling blocks, Cmd-Up zooms out, Return zooms in.
  private func handleNavigation(_ press: KeyPress) -> KeyPress.Result {
    let selected = session.selection.count == 1 ? session.selection.first : nil
    switch press.key {
    case .return:
      guard let selected else { return .ignored }
      if selected.isDirectory, selected !== focus {
        session.zoomIn(selected)
      } else if let parent = selected.parent, parent !== focus {
        session.zoomIn(parent)
      } else {
        return .ignored
      }
      return .handled
    case .upArrow where press.modifiers.contains(.command):
      guard session.canZoomOut else { return .ignored }
      session.zoomOut()
      return .handled
    default:
      let direction: TreemapNavigation.Direction
      switch press.key {
      case .upArrow: direction = .up
      case .downArrow: direction = .down
      case .leftArrow: direction = .left
      default: direction = .right
      }
      let next =
        selected.flatMap {
          TreemapNavigation.neighbor(of: $0, direction: direction, in: layout.rects)
        } ?? (selected == nil ? TreemapNavigation.firstBlock(under: focus, in: layout.rects) : nil)
      guard let next else { return .ignored }
      session.select(next)
      return .handled
    }
  }

  /// Invisible children that give VoiceOver the largest blocks; built from `elements`.
  private var accessibilityElements: some View {
    ZStack(alignment: .topLeading) {
      ForEach(elements) { block in
        Color.clear
          .frame(width: block.rect.width, height: block.rect.height)
          .offset(x: block.rect.minX, y: block.rect.minY)
          .accessibilityElement()
          .accessibilityLabel(block.label)
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { session.select(block.node) }
          .accessibilityAction(named: "Zoom In") {
            if block.isFolder { session.zoomIn(block.node) }
          }
      }
    }
  }

  /// The rect under a point in the view's coordinates, which include the outer padding.
  private func hit(at location: CGPoint) -> TreemapRect? {
    TreemapHitTest.rect(at: mapPoint(location), in: layout.rects)
  }

  /// The node under a point that can be selected; nil on a "small items" block.
  private func node(at location: CGPoint) -> FileNode? {
    TreemapHitTest.node(at: mapPoint(location), in: layout.rects)
  }

  private func mapPoint(_ location: CGPoint) -> CGPoint {
    CGPoint(x: location.x - Self.outerPadding, y: location.y - Self.outerPadding)
  }

  private func click(at location: CGPoint) {
    guard interactive else { return }
    isFocused = true
    let event = NSApp.currentEvent
    let clicks = event?.clickCount ?? 1
    if let rect = hit(at: location), case .smallItems = rect.kind {
      if clicks >= 2 {
        if rect.node !== focus { session.zoomIn(rect.node) }
      } else {
        session.selection = []
        session.smallItemsGroup = SmallItemsGroup(rect: rect)
      }
      return
    }
    guard let node = node(at: location) else {
      session.selection = []
      session.smallItemsGroup = nil
      return
    }
    if clicks >= 2 {
      if node.isDirectory, node !== focus { session.zoomIn(node) }
      return
    }
    session.select(node, extending: event?.modifierFlags.contains(.command) == true)
  }

  /// The node a context menu acts on: the hovered block.
  @ViewBuilder private var contextMenu: some View {
    if interactive, let node = session.hovered {
      Button("Open") { NSWorkspace.shared.open(node.url) }
      Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
      }
      if node.isDirectory, node !== focus {
        Button("Zoom In") { session.zoomIn(node) }
      }
      Divider()
      Button("Move to Trash") { delete(node, .moveToTrash) }
      Button("Delete Permanently…", role: .destructive) { delete(node, .deletePermanently) }
    }
  }

  /// Acts on the whole selection when `node` is part of it, otherwise on `node` alone.
  private func delete(_ node: FileNode, _ mode: DeletionMode) {
    if !session.selection.contains(node) { session.select(node) }
    onDelete(mode)
  }

  // MARK: Tooltip

  /// A fixed estimate of the tooltip's size, used to keep it inside the map.
  private static let tooltipSize = CGSize(width: 200, height: 36)

  @ViewBuilder private func tooltip(bounds: CGSize) -> some View {
    if let location = hoverLocation, let hit = hit(at: location) {
      let origin = TooltipPlacement.origin(
        cursor: location, size: Self.tooltipSize, bounds: bounds)
      VStack(alignment: .leading, spacing: 1) {
        Text(title(of: hit)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        if let subtitle = subtitle(of: hit) {
          Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        Text(ByteFormat.string(size(of: hit)))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .padding(.horizontal, Theme.spacingSM)
      .padding(.vertical, Theme.spacingXS)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
      .fixedSize()
      .offset(x: origin.x, y: origin.y)
    }
  }

  private func title(of rect: TreemapRect) -> String {
    if let group = SmallItemsGroup(rect: rect) { return group.title }
    return rect.node.name
  }

  private func subtitle(of rect: TreemapRect) -> String? {
    SmallItemsGroup(rect: rect)?.subtitle
  }

  private func size(of rect: TreemapRect) -> Int64 {
    SmallItemsGroup(rect: rect)?.size ?? rect.node.size
  }

  // MARK: Drawing

  private func draw(
    _ rects: [TreemapRect], marks: Highlights, in context: inout GraphicsContext
  ) {
    let dark = colorScheme == .dark
    let accent = Color.accentColor
    for item in rects {
      let frame = item.rect
      guard frame.width >= 1, frame.height >= 1 else { continue }
      switch item.kind {
      case .block:
        drawBlock(item, frame: frame, dark: dark, highlight: marks.category, in: &context)
      case .folderHeader:
        drawHeader(item, frame: frame, dark: dark, highlight: marks.category, in: &context)
      case .smallItems(let count, _):
        let fill = MapPalette.folderFill(depth: item.depth, darkMode: dark)
        let shown = CategoryHighlight.shown(
          fill, for: item, highlight: marks.category, root: focus, darkMode: dark)
        let path = Self.blockPath(frame)
        context.fill(path, with: .color(Color(shown.color)))
        Self.stroke(path, dark: dark, in: &context)
        drawLabel(
          "\(count) small items", in: frame, text: shown.color.labelColor, faded: shown.faded,
          context: &context)
      }

      guard item.kind != .folderHeader else { continue }
      let outline = Self.blockPath(frame)
      if !item.isSmallItems, item.node.nameMatches(marks.query) {
        context.stroke(outline, with: .color(.primary), lineWidth: Self.searchOutlineWidth)
      }
      if marks.selection.contains(item.node), !item.isSmallItems {
        context.stroke(outline, with: .color(accent), lineWidth: Self.selectionOutlineWidth)
      }
      if marks.hovered === item.node, item.kind == .block {
        context.fill(outline, with: .color(.white.opacity(0.12)))
        context.stroke(outline, with: .color(accent), lineWidth: Self.hoverOutlineWidth)
      }
    }
  }

  /// The rounded shape of a block inside its layout frame.
  private static func blockPath(_ frame: CGRect) -> Path {
    Path(
      roundedRect: frame.insetBy(dx: blockInset, dy: blockInset), cornerRadius: blockCornerRadius)
  }

  /// The thin outline of every block.
  private static func stroke(_ path: Path, dark: Bool, in context: inout GraphicsContext) {
    context.stroke(
      path, with: .color(.black.opacity(dark ? 0.35 : 0.1)), lineWidth: blockStrokeWidth)
  }

  private static let blockStrokeWidth: CGFloat = 0.5

  private func drawBlock(
    _ item: TreemapRect, frame: CGRect, dark: Bool, highlight: FileCategory?,
    in context: inout GraphicsContext
  ) {
    let shown = CategoryHighlight.shown(
      FileCategory.fill(for: item.node, depth: item.depth, darkMode: dark), for: item,
      highlight: highlight, root: focus, darkMode: dark)
    let rgb = shown.color
    let base = Color(rgb)
    let path = Self.blockPath(frame)
    context.fill(path, with: .color(base))
    Self.stroke(path, dark: dark, in: &context)
    if item.node.isDirectory { return }
    drawLabel(
      item.node.name, size: item.node.size, in: frame, text: rgb.labelColor,
      faded: shown.faded, context: &context)
  }

  private func drawHeader(
    _ item: TreemapRect, frame: CGRect, dark: Bool, highlight: FileCategory?,
    in context: inout GraphicsContext
  ) {
    guard frame.width > 24 else { return }
    let label = CategoryHighlight.headerText(
      item, fill: FileCategory.fill(for: item.node, depth: item.depth, darkMode: dark),
      highlight: highlight, root: focus, darkMode: dark)
    let color = Color(label.color).opacity(label.opacity)
    let size = Text(ByteFormat.string(item.node.size))
      .font(.system(size: 10.5))
      .foregroundStyle(color.opacity(0.7))
    let text = Text("\(item.node.name)  \(size)")
      .font(.system(size: 10.5, weight: .semibold))
      .foregroundStyle(color)
    var clipped = context
    let inner = frame.insetBy(dx: 4, dy: 1)
    clipped.clip(to: Path(inner))
    clipped.draw(clipped.resolve(text), in: inner)
  }

  /// Draws a file or small-items label when it fits inside the block. `text` is the block's
  /// `labelColor`, drawn at full opacity so it keeps its contrast; `faded` dims it with the block.
  private func drawLabel(
    _ name: String, size: Int64? = nil, in frame: CGRect, text: SpacerCore.RGBColor,
    faded: Bool, context: inout GraphicsContext
  ) {
    guard frame.width > 36, frame.height > 14 else { return }
    let base = Color(text)
    let color = faded ? base.opacity(0.5) : base
    let inner = frame.insetBy(dx: 4, dy: 2)
    var clipped = context
    clipped.clip(to: Path(inner))
    var lines = Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
    if let size, frame.height > 30 {
      let sizeText = Text(ByteFormat.string(size))
        .font(.system(size: 9)).foregroundStyle(color.opacity(0.75))
      lines = Text("\(lines)\n\(sizeText)")
    }
    clipped.draw(clipped.resolve(lines), in: inner)
  }
}

/// The blocks drawn with an outline or a highlight.
private struct Highlights {
  var selection: Set<FileNode>
  var hovered: FileNode?
  var query: String
  /// The category picked in the legend, if any.
  var category: FileCategory?
}

/// What the layout depends on. When it changes, the layout is recomputed.
private struct LayoutKey: Equatable {
  var size: CGSize
  var focus: ObjectIdentifier
  var tree: Int
}

/// The current layout, plus the frames it animates from after a resize.
private struct CachedLayout {
  private(set) var rects: [TreemapRect] = []
  private var start: [TreemapRect.Key: CGRect] = [:]
  private var startDate = Date.distantPast
  private var duration: TimeInterval = 0

  mutating func update(_ newRects: [TreemapRect], animated: Bool, duration: TimeInterval) {
    if animated {
      let now = Date()
      start = Dictionary(
        frames(at: now).map { ($0.key, $0.rect) }, uniquingKeysWith: { first, _ in first })
      startDate = now
      self.duration = duration
    } else {
      start = [:]
      self.duration = 0
    }
    rects = newRects
  }

  /// Ends an animation whose time is up.
  mutating func finishAnimation() {
    guard !isAnimating(at: Date()) else { return }
    duration = 0
    start = [:]
  }

  func isAnimating(at date: Date) -> Bool {
    duration > 0 && date.timeIntervalSince(startDate) < duration
  }

  /// The frames to draw at `date`: interpolated while an animation runs, final otherwise.
  func frames(at date: Date) -> [TreemapRect] {
    guard isAnimating(at: date) else { return rects }
    let linear = date.timeIntervalSince(startDate) / duration
    let eased = 1 - pow(1 - linear, 3)
    return rects.map { rect in
      guard let from = start[rect.key] else { return rect }
      return rect.interpolated(from: from, progress: eased)
    }
  }
}
