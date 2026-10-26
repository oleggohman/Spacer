import AppKit
import SpacerCore
import SwiftUI

/// Details of the selected item or small-items group, with its largest children and file actions.
struct InspectorView: View {
  let session: ScanSession
  let onDelete: (DeletionMode) -> Void

  var body: some View {
    let _ = session.treeVersion
    Group {
      if session.selection.count == 1, let node = session.selection.first {
        ItemInspector(node: node, session: session, onDelete: onDelete)
      } else if session.selection.count > 1 {
        VStack(spacing: Theme.spacingMD) {
          ContentUnavailableView(
            "\(session.selection.count) Items", systemImage: "square.stack",
            description: Text(ByteFormat.string(session.selectionSize)))
          DeleteButtons(onDelete: onDelete, isDeleting: session.isDeleting)
        }
        .padding(Theme.spacingMD)
      } else if let group = session.smallItemsGroup {
        GroupInspector(group: group, session: session)
      } else {
        ContentUnavailableView(
          "No Selection", systemImage: "cursorarrow.click",
          description: Text("Click a block in the map to see its details.")
        )
        .padding(Theme.spacingMD)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct DeleteButtons: View {
  let onDelete: (DeletionMode) -> Void
  /// True while a delete runs, so a second one cannot start.
  let isDeleting: Bool

  var body: some View {
    VStack(spacing: Theme.spacingSM) {
      Button {
        onDelete(.moveToTrash)
      } label: {
        Text("Move to Trash…").frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      Button(role: .destructive) {
        onDelete(.deletePermanently)
      } label: {
        Text("Delete Permanently…").frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
    }
    .font(.system(size: 13))
    .disabled(isDeleting)
  }
}

private struct ItemInspector: View {
  let node: FileNode
  let session: ScanSession
  let onDelete: (DeletionMode) -> Void
  /// Disk reads for `node`, made once per selected node and not on every render.
  @State private var loaded: Loaded?

  private struct Loaded {
    let node: FileNode
    let details: ItemDetails
    let icon: NSImage
  }

  var body: some View {
    let current = loaded.flatMap { $0.node === node ? $0 : nil }
    let details =
      current?.details ?? ItemDetails(kind: node.isDirectory ? "Folder" : "File", modified: nil)
    let unreadable = session.unreadableFolders.countUnder(node)
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.spacingMD) {
        HStack(alignment: .top, spacing: Theme.spacingSM) {
          Image(nsImage: current?.icon ?? NSImage())
            .resizable()
            .frame(width: 32, height: 32)
          VStack(alignment: .leading, spacing: 2) {
            Text(node.name)
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(2)
              .textSelection(.enabled)
            Text(node.url.path)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: Theme.spacingSM) {
          row("Size", node.accessDenied ? "Size unknown" : ByteFormat.string(node.size))
          if node.isDirectory {
            row("Items", (node.itemCount - 1).formatted())
          }
          row("Kind", details.kind)
          if let modified = details.modified {
            row("Modified", modified.formatted(date: .abbreviated, time: .shortened))
          }
          if node.accessDenied {
            Text("Spacer couldn’t read this folder.")
              .font(.system(size: 12))
              .foregroundStyle(.orange)
          } else if unreadable > 0 {
            Text(UnreadableFolders.includesText(count: unreadable))
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupedCard()

        if !node.children.isEmpty {
          LargestItemsCard(items: node.largestChildren(10), session: session)
        }

        VStack(spacing: Theme.spacingSM) {
          actionButton("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
          }
          actionButton("Open") { NSWorkspace.shared.open(node.url) }
          actionButton("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
          }
          DeleteButtons(onDelete: onDelete, isDeleting: session.isDeleting)
        }
        .font(.system(size: 13))
      }
      .padding(Theme.spacingMD)
    }
    .task(id: ObjectIdentifier(node)) {
      loaded = Loaded(
        node: node, details: ItemDetails.load(for: node),
        icon: NSWorkspace.shared.icon(forFile: node.url.path))
    }
  }

  private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
  }

  private func row(_ label: String, _ value: String) -> some View {
    LabeledContent {
      Text(value)
        .font(.system(size: 13))
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    } label: {
      Text(label)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
  }
}

/// What a click on a "N small items" block shows. Read-only: no file actions, no delete.
private struct GroupInspector: View {
  let group: SmallItemsGroup
  let session: ScanSession

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.spacingMD) {
        VStack(alignment: .leading, spacing: 2) {
          Text(group.title)
            .font(.system(size: 13, weight: .semibold))
          Text(group.subtitle)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
          Text(ByteFormat.string(group.size))
            .font(.system(size: 13))
          Text(group.parent.url.path)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        LargestItemsCard(items: group.largest(20), session: session)
      }
      .padding(Theme.spacingMD)
    }
  }
}

/// The "Largest Items" card of the item and group inspectors.
private struct LargestItemsCard: View {
  let items: [FileNode]
  let session: ScanSession

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Largest Items")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.bottom, Theme.spacingXS)
      ForEach(items) { child in
        ItemRow(child: child, session: session)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .groupedCard()
  }
}

/// A name and size row. A click selects the item; a double-click on a folder zooms into it.
private struct ItemRow: View {
  let child: FileNode
  let session: ScanSession
  @State private var isHovered = false

  var body: some View {
    HStack {
      Text(child.name).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: Theme.spacingSM)
      Text(ByteFormat.string(child.size))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .font(.system(size: 12))
    .padding(.horizontal, Theme.spacingSM)
    .padding(.vertical, Theme.spacingXS)
    .background(
      isHovered ? Color.primary.opacity(0.08) : .clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      if child.isDirectory { session.zoomIn(child) }
    }
    .onTapGesture { session.select(child) }
    .onHover { isHovered = $0 }
    .accessibilityAddTraits(.isButton)
  }
}
