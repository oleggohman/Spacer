import SpacerCore
import SwiftUI

/// The overlay shown while a scan runs. The compact style is a bar over the preview map.
struct ScanProgressView: View {
  let progress: ScanProgress
  var compact = false
  let onCancel: () -> Void

  var body: some View {
    if compact { bar } else { panel }
  }

  private var bar: some View {
    HStack(spacing: Theme.spacingMD) {
      ProgressView().controlSize(.small)
      Text(
        "Scanning… \(progress.filesScanned.formatted()) files · \(ByteFormat.string(progress.bytesScanned))"
      )
      .font(.system(size: 13))
      .monospacedDigit()
      .lineLimit(1)
      .fixedSize()
      Text(progress.currentPath)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Stop", role: .cancel, action: onCancel)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, Theme.spacingMD)
    .padding(.vertical, Theme.spacingSM)
    .frame(maxWidth: .infinity)
    .background(.bar)
  }

  private var panel: some View {
    VStack(spacing: Theme.spacingMD) {
      ProgressView()
        .progressViewStyle(.circular)
        .controlSize(.large)
      Text("Scanning…").font(.system(size: 17, weight: .semibold))
      HStack(spacing: Theme.spacingLG) {
        stat("Files", progress.filesScanned.formatted())
        stat("Size", ByteFormat.string(progress.bytesScanned))
      }
      Text(progress.currentPath)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity)
      Button("Stop", role: .cancel, action: onCancel)
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)
    }
    .padding(Theme.spacingMD)
    .frame(maxWidth: 360)
    .groupedCard()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func stat(_ title: String, _ value: String) -> some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.system(size: 15, weight: .semibold))
        .monospacedDigit()
      Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
    }
  }
}
