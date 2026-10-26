import SpacerCore
import SwiftUI

/// The bar under the map: one chip per file category with its color and its share of the
/// shown folder. Clicking a chip highlights that category in the map; clicking it again clears
/// the highlight.
struct CategoryLegendBar: View {
  let session: ScanSession
  /// The folder the map shows: the zoom focus, or the scan preview while a scan runs.
  let folder: FileNode

  @Environment(\.colorScheme) private var colorScheme

  private static let barHeight: CGFloat = 30
  private static let chipHeight: CGFloat = 22
  private static let chipSpacing: CGFloat = 5
  private static let dotSize: CGFloat = 9
  /// How strongly a selected chip is filled with its category color.
  private static let selectedFillOpacity = 0.2
  /// The opacity of chips other than the selected one, and of empty chips.
  private static let dimmedOpacity = 0.55

  var body: some View {
    // Read the tree version so a delete refreshes the shares.
    let _ = session.treeVersion
    let legend = CategoryLegend(for: folder)
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Theme.spacingXS) {
        ForEach(legend.shares) { share in
          chip(share)
        }
        if !legend.unlistedPercentText.isEmpty {
          Text("\(legend.unlistedPercentText) not listed yet")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.leading, Theme.spacingXS)
        }
      }
      .padding(.horizontal, Theme.spacingSM)
    }
    .frame(height: Self.barHeight)
    .frame(maxWidth: .infinity)
  }

  private func chip(_ share: CategoryShare) -> some View {
    let selected = session.highlightedCategory == share.category
    // A category this folder does not hold would only fade the whole map. A selected chip stays
    // clickable so its highlight can still be cleared.
    let empty = !share.canHighlight && !selected
    let dimmed = (session.highlightedCategory != nil && !selected) || empty
    let rgb = share.category.color(darkMode: colorScheme == .dark)
    return Button {
      session.toggleHighlight(share.category)
    } label: {
      HStack(spacing: Self.chipSpacing) {
        Circle()
          .fill(Color(rgb))
          .frame(width: Self.dotSize, height: Self.dotSize)
        Text(share.category.displayName)
          .font(.system(size: 11, weight: selected ? .semibold : .medium))
        if !share.percentText.isEmpty {
          Text(share.percentText)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
      .padding(.horizontal, Theme.spacingSM)
      .frame(height: Self.chipHeight)
      .background(selected ? Color(rgb).opacity(Self.selectedFillOpacity) : .clear, in: Capsule())
      .overlay(Capsule().strokeBorder(selected ? Color(rgb) : .clear, lineWidth: 1))
      .contentShape(Capsule())
      .opacity(dimmed ? Self.dimmedOpacity : 1)
    }
    .buttonStyle(.plain)
    .disabled(empty)
    .help(
      selected
        ? "Stop highlighting \(share.category.displayName.lowercased())"
        : "Highlight \(share.category.displayName.lowercased()) in the map")
  }
}
