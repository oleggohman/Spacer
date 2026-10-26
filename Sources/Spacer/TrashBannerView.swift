import SwiftUI

/// A short message under the map after a delete, with Undo for a Move to Trash.
struct TrashBannerView: View {
  let text: String
  let canUndo: Bool
  let onUndo: () -> Void
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: Theme.spacingSM) {
      Text(text)
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: Theme.spacingSM)
      if canUndo {
        Button("Undo", action: onUndo)
          .buttonStyle(.bordered)
          .font(.system(size: 13))
      }
      Button(action: onClose) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help("Dismiss")
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, Theme.spacingMD)
    .padding(.vertical, Theme.spacingSM)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.bannerRadius))
    .padding(Theme.spacingSM)
  }
}
