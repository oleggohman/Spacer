import AppKit
import SpacerCore
import SwiftUI

/// The strip above the map in the done state: the scanned size, what it is measured against, a
/// "Why different?" explanation and a warning when some folders could not be read.
struct ScanSummaryView: View {
  let session: ScanSession
  let volumes: [VolumeInfo]
  @State private var showWhyDifferent = false
  @State private var showUnreadable = false

  var body: some View {
    if let root = session.root, let url = session.scanURL {
      let unreadable = session.unreadableFolders
      // Refreshed every minute so "scanned N min ago" keeps up, like the sidebar row.
      TimelineView(.periodic(from: .now, by: 60)) { context in
        summaryContent(root: root, url: url, unreadable: unreadable, now: context.date)
      }
    }
  }

  private func summaryContent(
    root: FileNode, url: URL, unreadable: UnreadableFolders, now: Date
  ) -> some View {
    let summary = ScanSummary(
      root: root, scanURL: url, volumes: volumes, finishedAt: session.finishedAt,
      now: now, unreadableCount: unreadable.count)
    return VStack(alignment: .leading, spacing: Theme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.spacingSM) {
        Text(summary.sizeText)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.primary)
        if summary.isIncomplete {
          Text("\u{00B7} incomplete")
            .font(.system(size: 13))
            .foregroundStyle(.orange)
        }
        Text(summary.detailText)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if summary.volume != nil {
          Button("Why different?") { showWhyDifferent = true }
            .buttonStyle(.borderless)
            .font(.system(size: 13))
            .popover(isPresented: $showWhyDifferent) {
              Text(summary.whyDifferentText(unreadableCount: unreadable.count))
                .font(.system(size: 13))
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.spacingMD)
            }
        }
      }
      if unreadable.count > 0 || session.rootAccessDenied {
        warning(unreadable)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.spacingMD)
    .padding(.vertical, Theme.spacingSM)
  }

  private func warning(_ unreadable: UnreadableFolders) -> some View {
    HStack(spacing: Theme.spacingSM) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(
        UnreadableFolders.warningText(
          count: unreadable.count, rootDenied: session.rootAccessDenied,
          hasFullDiskAccess: session.hasFullDiskAccess)
      )
      .font(.system(size: 13))
      if session.suggestsFullDiskAccess {
        Button("Open Privacy Settings") {
          NSWorkspace.shared.open(FullDiskAccess.settingsURL)
        }
        .buttonStyle(.bordered)
      }
      if unreadable.count > 0 {
        Button("Show") { showUnreadable = true }
          .buttonStyle(.borderless)
          .font(.system(size: 13))
          .popover(isPresented: $showUnreadable) {
            UnreadableList(unreadable: unreadable)
          }
      }
    }
  }
}

/// The unreadable folders as paths, with a Reveal in Finder context menu on each.
private struct UnreadableList: View {
  let unreadable: UnreadableFolders

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.spacingXS) {
      ForEach(unreadable.shown(limit: 20), id: \.id) { node in
        Text(node.url.path)
          .font(.system(size: 12))
          .lineLimit(1)
          .truncationMode(.middle)
          .contextMenu {
            Button("Reveal in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
          }
      }
      let hidden = unreadable.hiddenCount(limit: 20)
      if hidden > 0 {
        Text(UnreadableFolders.moreText(hidden: hidden))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: 420, alignment: .leading)
    .padding(Theme.spacingMD)
  }
}
