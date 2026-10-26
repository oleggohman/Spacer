import Foundation

/// The colors of the map: Apple's system colors for the categories (light and dark mode), neutral
/// folder fills, and the two label colors. Views take their colors from here and from
/// `FileCategory`, not from raw values.
public enum MapPalette {
  public static let white = RGBColor(hex: 0xffffff)
  public static let black = RGBColor(hex: 0x000000)
  /// The label color on light fills: near black, the other choice is white.
  public static let darkLabel = RGBColor(hex: 0x0f0f10)

  /// Apple's system colors, light and dark. Each category takes one of these flat.
  public static func red(darkMode: Bool) -> RGBColor { pick(0xff3b30, 0xff453a, darkMode) }
  public static func orange(darkMode: Bool) -> RGBColor { pick(0xff9500, 0xff9f0a, darkMode) }
  public static func yellow(darkMode: Bool) -> RGBColor { pick(0xffcc00, 0xffd60a, darkMode) }
  public static func green(darkMode: Bool) -> RGBColor { pick(0x28cd41, 0x32d74b, darkMode) }
  public static func teal(darkMode: Bool) -> RGBColor { pick(0x59adc4, 0x6ac4dc, darkMode) }
  public static func purple(darkMode: Bool) -> RGBColor { pick(0xaf52de, 0xbf5af2, darkMode) }
  public static func pink(darkMode: Bool) -> RGBColor { pick(0xff2d55, 0xff375f, darkMode) }
  public static func gray(darkMode: Bool) -> RGBColor { pick(0x8e8e93, 0x98989d, darkMode) }

  /// How far one nesting level moves a folder fill.
  static let folderStep = 0.03
  /// Depths beyond this are drawn like this depth.
  public static let maxShadedDepth = 6

  /// The fill of a plain folder block at `depth` (0 is the top level). Light mode darkens and
  /// dark mode lightens a little per level, so nesting stays visible; the step is clamped at
  /// `maxShadedDepth`.
  public static func folderFill(depth: Int, darkMode: Bool) -> RGBColor {
    let step = folderStep * Double(min(max(depth, 0), maxShadedDepth))
    if darkMode {
      return RGBColor(hex: 0x2c2c2e).mixed(with: white, by: step)
    }
    return RGBColor(hex: 0xe5e5ea).mixed(with: black, by: step)
  }

  /// The map background that faded blocks move toward.
  public static func background(darkMode: Bool) -> RGBColor {
    pick(0xf5f5f7, 0x1e1e1e, darkMode)
  }

  private static func pick(_ light: UInt32, _ dark: UInt32, _ darkMode: Bool) -> RGBColor {
    RGBColor(hex: darkMode ? dark : light)
  }
}

extension RGBColor {
  /// A color from a 0xRRGGBB value.
  public init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255)
  }

  /// This color moved toward `other` by `amount` (0 keeps this color, 1 gives `other`).
  public func mixed(with other: RGBColor, by amount: Double) -> RGBColor {
    let t = min(max(amount, 0), 1)
    return RGBColor(
      red: red + (other.red - red) * t, green: green + (other.green - green) * t,
      blue: blue + (other.blue - blue) * t)
  }

  /// An sRGB component (0...1) converted to linear light.
  private static func linear(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  /// The color in CIE L*a*b* (D65 white point, normalized so sRGB white is exactly L 100):
  /// lightness 0...100 and the two color axes.
  var lab: (l: Double, a: Double, b: Double) {
    let r = Self.linear(red)
    let g = Self.linear(green)
    let b = Self.linear(blue)
    let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.9505
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.089
    func f(_ t: Double) -> Double {
      t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116
    }
    let fx = f(x)
    let fy = f(y)
    let fz = f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
  }

  /// The perceptual distance to `other` (CIE76 ΔE). Around 2 is just noticeable; 20 and more
  /// reads as a clearly different color.
  func distance(to other: RGBColor) -> Double {
    let p = lab
    let q = other.lab
    return ((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b))
      .squareRoot()
  }

  /// WCAG relative luminance, 0 (black) to 1 (white).
  public var luminance: Double {
    0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
  }

  /// The WCAG contrast ratio between this color and `other`, 1 (same) to 21 (black on white).
  public func contrastRatio(with other: RGBColor) -> Double {
    let lighter = max(luminance, other.luminance)
    let darker = min(luminance, other.luminance)
    return (lighter + 0.05) / (darker + 0.05)
  }

  /// True when white text reads better than `darkLabel` text on this color.
  public var prefersLightText: Bool {
    contrastRatio(with: MapPalette.white) > contrastRatio(with: MapPalette.darkLabel)
  }

  /// The label color for text drawn at full opacity on this color: white or `darkLabel`,
  /// whichever has more contrast.
  public var labelColor: RGBColor { prefersLightText ? MapPalette.white : MapPalette.darkLabel }
}
