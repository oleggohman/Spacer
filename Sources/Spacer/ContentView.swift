import AppKit
import SpacerCore
import SwiftUI

struct ContentView: View {
  @Bindable var session: ScanSession
  @State private var volumes = VolumeInfo.mounted()
  @State private var recents: [URL] = RecentScans().urls
  @State private var showInspector = true
  @State private var pendingDeletion: DeletionMode?
  /// Set after the first confirmation of a permanent delete, to ask a second time.
  @State private var confirmPermanentDeletion = false
  @State private var deletionFailures: [DeletionResult] = []
  @State private var restoreFailures: [DeletionResult] = []
  /// The text of the banner under the map after a delete, and a counter that tells a newer banner
  /// from the one a pending auto-dismiss belongs to.
  @State private var bannerText: String?
  @State private var bannerID = 0
  /// True while the search field has focus, where Cmd-Delete must edit text, not trash items.
  @FocusState private var searchFocused: Bool

  var body: some View {
    NavigationSplitView {
      SidebarView(
        session: session, volumes: volumes, recents: recents,
        onScan: scan, onRefreshVolumes: { volumes = VolumeInfo.mounted() }
      )
      .disabled(session.isDeleting)
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
    } detail: {
      detail
        .toolbar { toolbarContent }
        .searchable(text: $session.searchQuery, placement: .toolbar, prompt: "Find by name")
        .searchFocused($searchFocused)
        .inspector(isPresented: $showInspector) {
          InspectorView(session: session, onDelete: { pendingDeletion = $0 })
            .inspectorColumnWidth(min: 220, ideal: 250, max: 320)
        }
    }
    .onChange(of: session.isScanning) { _, scanning in
      // A new scan clears the undo, so its banner would be left without an Undo button.
      if scanning { bannerText = nil }
    }
    .focusedSceneValue(
      \.moveToTrash, canMoveToTrash ? MoveToTrashAction { pendingDeletion = .moveToTrash } : nil
    )
    .confirmationDialog(
      deletionTitle(pendingDeletion ?? .moveToTrash), isPresented: deletionDialogShown,
      titleVisibility: .visible
    ) {
      if pendingDeletion == .deletePermanently {
        Button("Delete Permanently…", role: .destructive) {
          pendingDeletion = nil
          confirmPermanentDeletion = true
        }
      } else {
        Button("Move to Trash") { performDeletion(.moveToTrash) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(deletionMessage)
    }
    .alert("Delete permanently? This cannot be undone.", isPresented: $confirmPermanentDeletion) {
      Button("Delete Permanently", role: .destructive) { performDeletion(.deletePermanently) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(deletionTitle(.deletePermanently))
    }
    .alert("The rescan failed", isPresented: rescanFailureShown) {
      Button("OK") { session.dismissRescanFailure() }
    } message: {
      Text("The previous scan is shown again. \(session.rescanFailure ?? "")")
    }
    .alert("Some items were not deleted", isPresented: failuresShown) {
      Button("OK") { deletionFailures = [] }
    } message: {
      Text(
        deletionFailures.map { "\($0.node.name): \($0.error?.message ?? "")" }
          .joined(separator: "\n"))
    }
    .alert("Some items could not be put back", isPresented: restoreFailuresShown) {
      Button("OK") { restoreFailures = [] }
    } message: {
      Text(
        restoreFailures.map { "\($0.node.name): \($0.error?.message ?? "")" }
          .joined(separator: "\n"))
    }
  }

  @ViewBuilder private var detail: some View {
    ZStack {
      switch session.state {
      case .idle:
        ContentUnavailableView(
          "No Scan", systemImage: "internaldrive",
          description: Text("Choose a volume or folder in the sidebar."))
      case .scanning(let progress):
        if let retained = session.retainedScan {
          withLegend(for: retained.focus) {
            TreemapView(
              session: session, focus: retained.focus, onDelete: { _ in }, interactive: false
            )
            .opacity(0.45)
          }
          .allowsHitTesting(false)
        } else if let preview = session.scanPreview {
          withLegend(for: preview) {
            TreemapView(session: session, focus: preview, onDelete: { _ in }, interactive: false)
          }
        } else {
          ScanProgressView(progress: progress, onCancel: session.cancel)
        }
      case .failed(let message):
        ContentUnavailableView {
          Label(
            "Couldn’t scan “\(failedName)”",
            systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again") { session.rescan() }
        }
      case .done:
        if let focus = session.focus {
          withLegend(for: focus) {
            TreemapView(session: session, focus: focus, onDelete: { pendingDeletion = $0 })
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        if case .scanning(let progress) = session.state,
          session.retainedScan != nil || session.scanPreview != nil
        {
          ScanProgressView(progress: progress, compact: true, onCancel: session.cancel)
        }
        if case .done = session.state {
          ScanSummaryView(session: session, volumes: volumes)
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let bannerText {
        TrashBannerView(
          text: bannerText, canUndo: session.undoableTrash != nil, onUndo: undo,
          onClose: {
            session.dismissUndo()
            self.bannerText = nil
          })
      }
    }
  }

  /// True when the Move to Trash menu command applies: a finished scan with a selection.
  private var canMoveToTrash: Bool {
    guard case .done = session.state else { return false }
    return !session.selection.isEmpty && !session.isDeleting && !searchFocused
  }

  private var failedName: String {
    session.scanURL?.lastPathComponent ?? "location"
  }

  /// The map with the category legend bar under it, when the legend is shown.
  private func withLegend(for folder: FileNode, @ViewBuilder map: () -> some View) -> some View {
    VStack(spacing: 0) {
      map()
      if session.isLegendVisible {
        CategoryLegendBar(session: session, folder: folder)
          .padding(.bottom, Theme.spacingXS)
      }
    }
  }

  @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button(action: session.goBack) {
        Label("Back", systemImage: "chevron.left")
      }
      .help("Back")
      .disabled(!session.canGoBack)
      Button(action: session.goForward) {
        Label("Forward", systemImage: "chevron.right")
      }
      .help("Forward")
      .disabled(!session.canGoForward)
    }
    ToolbarItem(placement: .principal) {
      BreadcrumbBar(session: session)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      if session.isScanning {
        Button {
          session.cancel()
        } label: {
          Label("Stop", systemImage: "stop.fill")
        }
        .help("Stop the scan")
      } else {
        Button {
          session.rescan()
        } label: {
          Label(
            session.root == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
        }
        .help(
          session.root == nil
            ? "Scan"
            : session.rescansFocusOnly ? "Rescan this folder" : "Rescan"
        )
        .disabled(session.scanURL == nil || session.isDeleting)
      }
      Button {
        showInspector.toggle()
      } label: {
        Label("Inspector", systemImage: "sidebar.trailing")
      }
      .help("Show or hide the inspector")
    }
  }

  private func scan(_ url: URL) {
    guard !session.isDeleting else { return }
    recents = RecentScans().add(url)
    session.open(url: url)
  }

  private func deletionTitle(_ mode: DeletionMode) -> String {
    DeletionPrompt.title(
      mode: mode, count: session.selectionTopmost.count, size: session.selectionSize)
  }

  /// The names of the items to delete, largest first, and a note for permanent deletes.
  private var deletionMessage: String {
    DeletionPrompt.message(
      mode: pendingDeletion ?? .moveToTrash, names: session.selectionTopmost.map(\.name))
  }

  private var deletionDialogShown: Binding<Bool> {
    Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
  }

  private var rescanFailureShown: Binding<Bool> {
    Binding(
      get: { session.rescanFailure != nil },
      set: { if !$0 { session.dismissRescanFailure() } })
  }

  private var failuresShown: Binding<Bool> {
    Binding(get: { !deletionFailures.isEmpty }, set: { if !$0 { deletionFailures = [] } })
  }

  private var restoreFailuresShown: Binding<Bool> {
    Binding(get: { !restoreFailures.isEmpty }, set: { if !$0 { restoreFailures = [] } })
  }

  private func performDeletion(_ mode: DeletionMode) {
    let nodes = session.selection
    pendingDeletion = nil
    Task {
      let results = await session.delete(nodes, mode: mode)
      // Empty when a delete or scan was already running: leave the current banner alone.
      guard !results.isEmpty else { return }
      deletionFailures = results.filter { !$0.succeeded }
      volumes = VolumeInfo.mounted()
      showBanner(
        mode == .moveToTrash
          ? session.undoableTrash?.summaryText ?? DeletionSummary.trashed(results: results)
          : DeletionSummary.deleted(results: results))
    }
  }

  private func undo() {
    Task {
      let results = await session.undoLastTrash()
      restoreFailures = results.filter { !$0.succeeded }
      volumes = VolumeInfo.mounted()
      if !results.isEmpty { bannerText = nil }
    }
  }

  /// Shows the banner for 8 seconds, unless a newer one replaces it first.
  private func showBanner(_ text: String?) {
    bannerID += 1
    bannerText = text
    guard text != nil else { return }
    let id = bannerID
    Task {
      try? await Task.sleep(for: .seconds(8))
      if bannerID == id {
        bannerText = nil
        session.dismissUndo()
      }
    }
  }
}

/// The scan path from the root to the zoom focus. Each segment zooms to that folder.
struct BreadcrumbBar: View {
  let session: ScanSession

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(session.breadcrumbs.enumerated()), id: \.element.id) { index, node in
        if index > 0 {
          Image(systemName: "chevron.right")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        Button(node.name) { session.zoomTo(node) }
          .buttonStyle(.borderless)
          .lineLimit(1)
          .font(.system(size: 13, weight: node === session.focus ? .semibold : .regular))
          .foregroundStyle(node === session.focus ? .primary : .secondary)
      }
    }
    .frame(maxWidth: 520)
  }
}
