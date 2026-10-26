import SpacerCore
import SwiftUI

extension Color {
  init(_ rgb: SpacerCore.RGBColor) {
    self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
  }
}

enum Theme {
  /// Spacing scale.
  static let spacingXS: CGFloat = 4
  static let spacingSM: CGFloat = 8
  static let spacingMD: CGFloat = 16
  static let spacingLG: CGFloat = 24

  /// Corner radius of grouped cards and map containers.
  static let cardRadius: CGFloat = 10
  /// Corner radius of the banner under the map.
  static let bannerRadius: CGFloat = 8
}

/// An inset group, like the ones in System Settings.
struct GroupedCard: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(12)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
  }
}

extension View {
  func groupedCard() -> some View {
    modifier(GroupedCard())
  }
}
