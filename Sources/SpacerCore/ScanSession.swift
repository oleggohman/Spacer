import Foundation
import Observation

/// A mounted volume shown in the sidebar.
public struct VolumeInfo: Sendable, Hashable, Identifiable {
  public let url: URL
  public let name: String
  public let totalCapacity: Int64
  public let availableCapacity: Int64

  public var id: URL { url }
  public var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

  /// Share of the volume in use, 0...1. Zero when the capacity is unknown.
  public var usedFraction: Double {
    guard totalCapacity > 0 else { return 0 }
    return min(1, Double(usedCapacity) / Double(totalCapacity))
  }

  public init(url: URL, name: String, totalCapacity: Int64, availableCapacity: Int64) {
    self.url = url
    self.name = name
    self.totalCapacity = totalCapacity
    self.availableCapacity = availableCapacity
  }

  /// The visible mounted volumes, in the order the system reports them.
  public static func mounted() -> [VolumeInfo] {
    let keys: [URLResourceKey] = [
      .volumeLocalizedNameKey, .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ]
    let urls =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    return urls.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
      let available =
        values.volumeAvailableCapacityForImportantUsage
        ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
      return VolumeInfo(
        url: url, name: values.volumeLocalizedName ?? url.lastPathComponent,
        totalCapacity: Int64(values.volumeTotalCapacity ?? 0), availableCapacity: available)
    }
  }
}

/// The previous scan of a location, kept while a same-location rescan runs so the old map stays
/// up until the new scan finishes. Nothing else refers to this tree, so it is freed with the struct.
public struct RetainedScan {
  /// The scan root of the previous scan.
  public let root: FileNode
  /// The folder that was zoomed into.
  public let focus: FileNode
  /// The zoom history before `focus`, most recent last.
  public let backStack: [FileNode]
  /// The zoom history `goBack()` left, most recent last.
  public let forwardStack: [FileNode]
  /// When the previous scan finished.
  public let finishedAt: Date?
  /// The unreadable folders of the previous scan.
  public let unreadableFolders: UnreadableFolders
  /// Whether the previous scan had Full Disk Access.
  public let hasFullDiskAccess: Bool
}

/// The state of the app window: the current scan, what is zoomed into, and what is selected.
@MainActor @Observable
public final class ScanSession {
  public enum State {
    case idle
    case scanning(ScanProgress)
    case done(FileNode)
    case failed(String)
  }

  public private(set) var state: State = .idle
  /// The folder or volume being scanned or last scanned.
  public private(set) var scanURL: URL?
  /// `scanURL` with links resolved, taken when the scan starts, so a link retargeted later does
  /// not make `open(url:)` show the old tree under the new target.
  private var scanPath: String?
  public private(set) var root: FileNode?
  /// When the current scan finished. Nil while a scan runs, after a failure, and before any scan.
  /// `open(url:)` keeps it, so showing a finished scan again keeps its age. A rescan of the
  /// zoomed-in folder sets it to when that rescan finished.
  public private(set) var finishedAt: Date?
  /// The node the treemap shows. Nil until a scan finishes.
  public private(set) var focus: FileNode?
  /// A rough tree of what the running scan has found so far, for a read-only map while it runs.
  /// Its nodes are not part of `root`, so it must never be selected, zoomed or deleted from.
  public private(set) var scanPreview: FileNode?
  /// Earlier zoom focuses, most recent last, for `goBack()`.
  private var backStack: [FileNode] = []
  /// Focuses that `goBack()` left, most recent last, for `goForward()`.
  private var forwardStack: [FileNode] = []
  /// The previous scan while a same-location rescan runs. Nil otherwise, and once it finishes or
  /// is stopped. A rescan of the zoomed-in folder (see `rescan()`) keeps it too, and then only that
  /// folder is replaced when it finishes.
  public private(set) var retainedScan: RetainedScan?
  public var selection: Set<FileNode> = []
  /// The "N small items" block the user clicked, shown read-only in the inspector. It is kept
  /// apart from `selection` so that file actions never reach it. Cleared by a selection, a new
  /// scan and a delete.
  public var smallItemsGroup: SmallItemsGroup?
  public var hovered: FileNode?
  /// True while a delete runs. A second delete is ignored until the first one finishes.
  public private(set) var isDeleting = false
  /// The last Move to Trash, which `undoLastTrash()` puts back. Nil after a permanent delete, a
  /// new scan, `dismissUndo()`, and the next delete.
  public private(set) var undoableTrash: TrashBatch?
  /// Why the last same-location rescan failed, while the previous map is shown again. Cleared when
  /// a scan starts and by `dismissRescanFailure()`.
  public private(set) var rescanFailure: String?
  /// Bumped whenever the tree changes in place, so views recompute their layout.
  public private(set) var treeVersion = 0
  /// Text typed in the search field. Matching blocks are highlighted in the map.
  /// Only the drawn blocks are checked (with `FileNode.nameMatches`), so typing never walks the whole tree.
  public var searchQuery = ""
  /// The category picked in the legend. Its blocks stay bright and the rest of the map fades.
  /// Cleared by a new scan and by hiding the legend.
  public private(set) var highlightedCategory: FileCategory?
  /// True while the category legend is shown under the map. Shown by default.
  public private(set) var isLegendVisible = true

  /// Highlights `category`, or clears the highlight when it is already highlighted.
  public func toggleHighlight(_ category: FileCategory) {
    highlightedCategory = highlightedCategory == category ? nil : category
  }

  /// Shows or hides the legend. Hiding it also clears the highlight, since there would be no
  /// chip left to clear it with.
  public func setLegendVisible(_ visible: Bool) {
    isLegendVisible = visible
    if !visible { highlightedCategory = nil }
  }

  private let scanner: DiskScanner
  private let homeDirectory: URL
  private let fullDiskAccessProbe: @Sendable () -> Bool
  private var scanTask: Task<Void, Never>?
  private var progressTask: Task<Void, Never>?
  private var generation = 0
  /// The folder a partial rescan (see `rescan()`) replaces. Nil for a full scan.
  private var rescanTarget: FileNode?

  public init(
    scanner: DiskScanner = DiskScanner(),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fullDiskAccessProbe: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted() }
  ) {
    self.scanner = scanner
    self.homeDirectory = homeDirectory
    self.fullDiskAccessProbe = fullDiskAccessProbe
  }

  public var isScanning: Bool {
    if case .scanning = state { return true }
    return false
  }

  /// True when the scan root itself could not be read (usually Full Disk Access is missing).
  public var rootAccessDenied: Bool { root?.accessDenied == true }

  /// The folders under the scan root that could not be read. Collected once when the scan
  /// finishes, so it is empty while a scan runs.
  public private(set) var unreadableFolders = UnreadableFolders([])

  /// Whether the app had Full Disk Access when the scan finished. Checked by the probe at that
  /// point, so the summary can tell a protected folder from one Full Disk Access would unlock.
  public private(set) var hasFullDiskAccess = true

  /// True when the summary warns about unreadable folders and Full Disk Access could unlock them,
  /// so the summary offers the Privacy Settings button.
  public var suggestsFullDiskAccess: Bool {
    (rootAccessDenied || unreadableFolders.count > 0) && !hasFullDiskAccess
  }

  /// The path from the scan root down to the focus, used for the breadcrumb bar.
  public var breadcrumbs: [FileNode] { focus?.ancestry ?? [] }

  // MARK: Scanning

  public func start(url: URL) {
    stopTasks()
    generation += 1
    let current = generation
    let path = Self.normalizedPath(url)
    if path != scanPath {
      discard(retainedScan?.root)
      discard(root)
      retainedScan = nil
    } else if case .done = state, !isDeleting, let root, let focus {
      // Not while a delete runs: it ends early when the generation changes, so the retained tree
      // would keep items that are gone from disk.
      retainedScan = RetainedScan(
        root: root, focus: focus, backStack: backStack, forwardStack: forwardStack,
        finishedAt: finishedAt, unreadableFolders: unreadableFolders,
        hasFullDiskAccess: hasFullDiskAccess)
    }
    scanURL = url
    scanPath = path
    rescanTarget = nil
    clearShownScan()
    run(url: url, generation: current)
  }

  /// Clears what the previous scan showed. Used when a scan starts, whether of the whole location
  /// or of one folder.
  private func clearShownScan() {
    root = nil
    finishedAt = nil
    focus = nil
    backStack = []
    forwardStack = []
    selection = []
    smallItemsGroup = nil
    hovered = nil
    highlightedCategory = nil
    scanPreview = nil
    unreadableFolders = UnreadableFolders([])
    undoableTrash = nil
    rescanFailure = nil
  }

  /// Scans `url` in the background, with the progress stream feeding `state`. The results go to
  /// `finish` or `fail` only while `current` is still the generation, so a stale scan is ignored.
  private func run(url: URL, generation current: Int) {
    state = .scanning(ScanProgress(filesScanned: 0, bytesScanned: 0, currentPath: url.path))
    let (stream, continuation) = AsyncStream.makeStream(
      of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
    progressTask = Task { [weak self] in
      for await progress in stream {
        guard let self, self.generation == current, self.isScanning else { continue }
        self.state = .scanning(progress)
        if let preview = progress.preview, preview !== self.scanPreview {
          self.scanPreview = preview
        }
      }
    }
    let scanner = self.scanner
    scanTask = Task { [weak self] in
      do {
        let node = try await scanner.scan(url, progress: continuation)
        self?.finish(node, generation: current)
      } catch is CancellationError {
        // `cancel()` already reset the state.
      } catch {
        self?.fail(error, generation: current)
      }
    }
  }

  /// Stops a running scan. A same-location rescan goes back to the previous result. Any other
  /// scan leaves the previous result gone, so the session goes back to idle.
  public func cancel() {
    guard isScanning else { return }
    stopTasks()
    generation += 1
    rescanTarget = nil
    scanPreview = nil
    guard restoreRetainedScan() else {
      unreadableFolders = UnreadableFolders([])
      state = .idle
      return
    }
  }

  /// Puts the retained scan back as the current one. False when there is none.
  private func restoreRetainedScan() -> Bool {
    guard let retained = retainedScan else { return false }
    root = retained.root
    focus = retained.focus
    backStack = retained.backStack
    forwardStack = retained.forwardStack
    finishedAt = retained.finishedAt
    unreadableFolders = retained.unreadableFolders
    hasFullDiskAccess = retained.hasFullDiskAccess
    retainedScan = nil
    state = .done(retained.root)
    return true
  }

  /// True when `rescan()` rescans only the zoomed-in folder, which is when a finished scan is
  /// zoomed into a folder below the root. At the root, or with no finished scan, it rescans the
  /// whole location.
  public var rescansFocusOnly: Bool {
    guard case .done = state, !isDeleting, let root, let focus else { return false }
    return focus !== root && focus.isDirectory && focus.parent != nil
  }

  /// Rescans the scan location again. When `rescansFocusOnly` is true, only the zoomed-in folder is
  /// rescanned and its new tree replaces the old one, so the rest of the tree is kept. Otherwise the
  /// whole location is scanned.
  public func rescan() {
    guard let scanURL else { return }
    guard rescansFocusOnly, let root, let focus else {
      start(url: scanURL)
      return
    }
    rescanFolder(
      focus,
      keeping: RetainedScan(
        root: root, focus: focus, backStack: backStack, forwardStack: forwardStack,
        finishedAt: finishedAt, unreadableFolders: unreadableFolders,
        hasFullDiskAccess: hasFullDiskAccess))
  }

  /// Scans only `folder`, a folder of the finished scan in `retained`, and keeps `retained` as the
  /// map until the new scan finishes. The scan location is unchanged, so `scanURL` and `scanPath`
  /// stay as they are.
  private func rescanFolder(_ folder: FileNode, keeping retained: RetainedScan) {
    stopTasks()
    generation += 1
    retainedScan = retained
    rescanTarget = folder
    clearShownScan()
    run(url: folder.url, generation: generation)
  }

  /// Shows the current scan when `url` is the folder being scanned or already scanned. A finished
  /// scan is shown from the root again. A running scan is left alone. Any other URL, and a scan
  /// that failed or was cancelled, starts a new scan. Only `rescan()` rescans the same URL.
  /// Showing the root is a zoom like `zoomTo`: the tree is unchanged, so selection, hover and the
  /// category highlight stay as they are and `treeVersion` is not bumped.
  public func open(url: URL) {
    guard scanURL != nil, scanPath == Self.normalizedPath(url) else {
      start(url: url)
      return
    }
    switch state {
    case .scanning:
      return
    case .done:
      focus = root
      backStack = []
      forwardStack = []
    case .idle, .failed:
      start(url: url)
    }
  }

  /// The path with links resolved (so /var and /private/var match), standardized, without a
  /// trailing slash.
  private static func normalizedPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.resolvingSymlinksInPath().path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path
  }

  /// Waits until the running scan, if any, has finished or been cancelled.
  public func waitForScan() async {
    await scanTask?.value
    await progressTask?.value
  }

  private func stopTasks() {
    scanTask?.cancel()
    progressTask?.cancel()
    scanTask = nil
    progressTask = nil
  }

  private func finish(_ node: FileNode, generation: Int) {
    guard generation == self.generation else { return }
    if let target = rescanTarget {
      finishFolderRescan(node, replacing: target)
      return
    }
    root = node
    finishedAt = Date()
    focus = node
    backStack = []
    forwardStack = []
    scanPreview = nil
    discard(retainedScan?.root)
    retainedScan = nil
    unreadableFolders = UnreadableFolders(node.unreadableFolders())
    hasFullDiskAccess = fullDiskAccessProbe()
    state = .done(node)
  }

  /// Puts the rescanned `scanned` folder in place of `target` and keeps the rest of the retained
  /// tree, so its nodes and their sizes stay. A folder that is no longer a folder fails the rescan,
  /// which restores the previous map.
  private func finishFolderRescan(_ scanned: FileNode, replacing target: FileNode) {
    rescanTarget = nil
    guard let retained = retainedScan, retained.root.contains(target), let parent = target.parent,
      scanned.isDirectory
    else {
      fail(
        NSError(
          domain: "Spacer", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "The folder is no longer a folder."]),
        generation: generation)
      return
    }
    // The scanner names its root with the display name, which may differ from the real one, so the
    // node takes the target's name and url. Its children move to the new node.
    let fresh = FileNode(
      name: target.name, url: target.url, children: scanned.children,
      isPackage: target.isPackage, accessDenied: scanned.accessDenied)
    target.remove()
    parent.attach(fresh)

    _ = restoreRetainedScan()
    // The map now shows what the rescan found, so its age counts from the rescan.
    finishedAt = Date()
    scanPreview = nil
    focus = fresh
    backStack = Self.replacing(target, with: fresh, in: backStack, within: retained.root)
    forwardStack = Self.replacing(target, with: fresh, in: forwardStack, within: retained.root)
    unreadableFolders =
      unreadableFolders.removing(under: [target]).adding(fresh.unreadableFolders())
    hasFullDiskAccess = fullDiskAccessProbe()
    treeVersion += 1
    discard(target)
  }

  /// Takes apart a tree that is no longer shown: every folder in it drops its children.
  ///
  /// SwiftUI can keep closures of views that are gone (key press handlers, button actions), and
  /// they capture the nodes those views showed. One such reference to a root kept a whole scan,
  /// millions of nodes, alive after every rescan. Emptying the folders frees all of it, and a
  /// stray reference keeps only one empty node. It runs on the main actor, where the tree is
  /// read, in batches so the app stays responsive while millions of nodes are freed.
  private func discard(_ tree: FileNode?) {
    guard let tree else { return }
    Task {
      var pending = [tree]
      var emptied = 0
      while let node = pending.popLast() {
        pending.append(contentsOf: node.children)
        node.children = []
        emptied += 1
        if emptied.isMultiple(of: Self.discardBatch) { await Task.yield() }
      }
      // malloc keeps freed pages for reuse, so Activity Monitor would still show the old tree.
      // Hand them back to the system now that millions of nodes were freed.
      malloc_zone_pressure_relief(nil, 0)
    }
  }

  /// How many folders `discard` empties between yields to the main actor.
  private static let discardBatch = 20_000

  /// `nodes` with `target` swapped for `fresh`, leaving out the nodes that are no longer in `root`.
  /// Nodes inside the replaced folder are no longer in the tree, so they are left out too.
  private static func replacing(
    _ target: FileNode, with fresh: FileNode, in nodes: [FileNode], within root: FileNode
  ) -> [FileNode] {
    nodes.map { $0 === target ? fresh : $0 }.filter { root.contains($0) }
  }

  private func fail(_ error: any Error, generation: Int) {
    guard generation == self.generation else { return }
    rescanTarget = nil
    scanPreview = nil
    // A same-location rescan that fails keeps the previous map, and `rescanFailure` tells why.
    if restoreRetainedScan() {
      rescanFailure = error.localizedDescription
      return
    }
    state = .failed(error.localizedDescription)
  }

  // MARK: Zoom

  /// Shows `node` full size. A file zooms to the folder that holds it.
  public func zoomIn(_ node: FileNode) {
    guard let root, root.contains(node) else { return }
    navigate(to: node.isDirectory ? node : (node.parent ?? root))
  }

  /// Goes up one level, stopping at the scan root.
  public func zoomOut() {
    guard let focus, let parent = focus.parent, focus !== root else { return }
    navigate(to: parent)
  }

  /// Jumps to an entry of `breadcrumbs`.
  public func zoomTo(_ node: FileNode) {
    guard let root, root.contains(node), node.isDirectory else { return }
    navigate(to: node)
  }

  public var canZoomOut: Bool { focus != nil && focus !== root }

  /// Returns to the previous focus, like a browser's back button.
  public func goBack() {
    while let previous = backStack.popLast() {
      guard previous !== focus else { continue }
      if let focus { forwardStack.append(focus) }
      self.focus = previous
      return
    }
  }

  public var canGoBack: Bool { backStack.contains { $0 !== focus } }

  /// Undoes `goBack()`, like a browser's forward button.
  public func goForward() {
    while let next = forwardStack.popLast() {
      guard next !== focus else { continue }
      if let focus { backStack.append(focus) }
      self.focus = next
      return
    }
  }

  public var canGoForward: Bool { forwardStack.contains { $0 !== focus } }

  /// Moves the focus to `node` and remembers the old focus for `goBack()`. A new zoom ends the
  /// forward history.
  private func navigate(to node: FileNode) {
    guard let focus, node !== focus else { return }
    backStack.append(focus)
    forwardStack = []
    self.focus = node
  }

  // MARK: Selection

  /// Selects `node`. With `extending` it is added to or removed from the selection instead.
  public func select(_ node: FileNode, extending: Bool = false) {
    smallItemsGroup = nil
    if extending {
      if selection.remove(node) == nil { selection.insert(node) }
    } else {
      selection = [node]
    }
  }

  /// The selected nodes that are not inside another selected node, largest first. These are
  /// what a delete removes, so the confirmation counts and lists them.
  public var selectionTopmost: [FileNode] {
    Self.topmost(selection).sorted { $0.size > $1.size }
  }

  public var selectionSize: Int64 { Self.topmost(selection).reduce(0) { $0 + $1.size } }

  // MARK: Deleting

  /// Deletes `nodes` from disk and removes the ones that succeeded from the tree, without
  /// rescanning. Returns one result per node, or no results when another delete is running.
  /// If a new scan starts meanwhile, the old tree is left alone.
  @discardableResult
  public func delete(_ nodes: Set<FileNode>, mode: DeletionMode) async -> [DeletionResult] {
    guard let root, !isDeleting else { return [] }
    isDeleting = true
    defer { isDeleting = false }
    let current = generation
    // Parents first, so that items inside a deleted folder are reported with it.
    let ordered = nodes.sorted { $0.ancestry.count < $1.ancestry.count }
    let service = DeletionService(root: root.url, homeDirectory: homeDirectory)
    let results = await service.delete(nodes: ordered, mode: mode)
    guard current == generation else { return results }

    let removed = Self.topmost(Set(results.filter(\.succeeded).map(\.node)))
    // Taken before `remove()`, which detaches each node from its parent.
    let trashed = results.compactMap { result -> TrashBatch.Item? in
      guard result.succeeded, let trashedURL = result.trashedURL, let parent = result.node.parent
      else { return nil }
      return TrashBatch.Item(node: result.node, parent: parent, trashedURL: trashedURL)
    }
    // Nothing to undo unless every removed item has a Trash location (the system may report none).
    undoableTrash =
      mode == .moveToTrash && !trashed.isEmpty && trashed.count == removed.count
      ? TrashBatch(items: trashed) : nil
    for node in removed {
      if let focus, node.contains(focus) { self.focus = node.parent ?? root }
      if let hovered, node.contains(hovered) { self.hovered = nil }
      node.remove()
    }
    unreadableFolders = unreadableFolders.removing(under: removed)
    selection = selection.filter { item in !removed.contains { $0.contains(item) } }
    smallItemsGroup = nil
    backStack.removeAll { !root.contains($0) }
    forwardStack.removeAll { !root.contains($0) }
    treeVersion += 1
    state = .done(root)
    return results
  }

  /// Hides `rescanFailure` once the user has seen it.
  public func dismissRescanFailure() {
    rescanFailure = nil
  }

  /// Hides the undo for the last Move to Trash. The items stay in the Trash.
  public func dismissUndo() {
    undoableTrash = nil
  }

  /// Puts the items of the last Move to Trash back from the Trash and reattaches them to the tree.
  /// Returns one result per item, or no results when there is nothing to undo or a delete runs.
  /// An item whose original path is taken again stays in the Trash and is reported as failed.
  @discardableResult
  public func undoLastTrash() async -> [DeletionResult] {
    guard let batch = undoableTrash, let root, !isDeleting else { return [] }
    isDeleting = true
    defer { isDeleting = false }
    let current = generation
    let service = DeletionService(root: root.url, homeDirectory: homeDirectory)
    var results: [DeletionResult] = []
    var reattached = false
    var restoredUnreadable: [FileNode] = []
    for item in batch.items {
      let error = await service.restore(trashedURL: item.trashedURL, to: item.node.url)
      // A scan that started meanwhile replaced the tree, so the item is only put back on disk.
      if error == nil, current == generation, root.contains(item.parent) {
        item.parent.attach(item.node)
        reattached = true
        restoredUnreadable += item.node.unreadableFolders()
      }
      results.append(DeletionResult(node: item.node, error: error, trashedURL: nil))
    }
    guard current == generation else { return results }

    undoableTrash = nil
    if reattached {
      unreadableFolders = unreadableFolders.adding(restoredUnreadable)
      treeVersion += 1
    }
    state = .done(root)
    return results
  }

  /// The nodes that are not inside another node of the set.
  nonisolated static func topmost(_ nodes: Set<FileNode>) -> [FileNode] {
    nodes.filter { node in !nodes.contains { $0 !== node && $0.contains(node) } }
  }
}
