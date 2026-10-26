import Foundation
import Testing

@testable import SpacerCore

@Suite struct FileCategoryTests {
  @Test(arguments: [
    ("mp4", FileCategory.video), ("MOV", .video), ("mp3", .audio), ("flac", .audio),
    ("jpg", .images), ("HEIC", .images), ("pdf", .documents), ("docx", .documents),
    ("swift", .code), ("ts", .code), ("zip", .archives), ("dmg", .archives), ("app", .apps),
    ("", .other), ("qqqzzz", .other),
  ])
  func extensionMapsToCategory(ext: String, expected: FileCategory) {
    #expect(FileCategory.of(extension: ext) == expected)
  }

  @Test func systemTypesAreUsedForUnlistedExtensions() {
    #expect(FileCategory.of(extension: "m2ts") == .video)
    #expect(FileCategory.of(extension: "aifc") == .audio)
    #expect(FileCategory.of(extension: "jp2") == .images)
  }

  @Test func nodesAreCategorized() {
    let file = FileNode(name: "song.m4a", url: URL(fileURLWithPath: "/x/song.m4a"), size: 1)
    let folder = FileNode(name: "x", url: URL(fileURLWithPath: "/x"), children: [])
    let app = FileNode(
      name: "Tool.app", url: URL(fileURLWithPath: "/x/Tool.app"), children: [], isPackage: true)
    let bundle = FileNode(
      name: "Lib.bundle", url: URL(fileURLWithPath: "/x/Lib.bundle"), children: [],
      isPackage: true)
    #expect(FileCategory.of(file) == .audio)
    #expect(FileCategory.of(folder) == .folders)
    #expect(FileCategory.of(app) == .apps)
    #expect(FileCategory.of(bundle) == .folders)
  }

  @Test func colorsAndFolderFillsStayInRange() {
    for dark in [false, true] {
      let fills =
        FileCategory.allCases.map { $0.color(darkMode: dark) }
        + (0...MapPalette.maxShadedDepth).map { MapPalette.folderFill(depth: $0, darkMode: dark) }
      for c in fills {
        #expect((0...1).contains(c.red) && (0...1).contains(c.green) && (0...1).contains(c.blue))
      }
    }
  }

  @Test func categoryColorsDifferBetweenModes() {
    for category in FileCategory.allCases {
      #expect(category.color(darkMode: false) != category.color(darkMode: true), "\(category)")
    }
  }

  @Test(arguments: [false, true])
  func folderFillsChangeWithDepthAndClampAtTheMaximum(darkMode: Bool) {
    for depth in 0..<MapPalette.maxShadedDepth {
      #expect(
        MapPalette.folderFill(depth: depth, darkMode: darkMode)
          != MapPalette.folderFill(depth: depth + 1, darkMode: darkMode))
    }
    let deepest = MapPalette.folderFill(depth: MapPalette.maxShadedDepth, darkMode: darkMode)
    #expect(MapPalette.folderFill(depth: 9, darkMode: darkMode) == deepest)
    #expect(
      MapPalette.folderFill(depth: -1, darkMode: darkMode)
        == MapPalette.folderFill(
          depth: 0, darkMode: darkMode))
  }

  /// The legend's eight categories (folders have no chip) must read as different colors.
  @Test(arguments: [false, true])
  func legendCategoriesAreWellSeparated(darkMode: Bool) {
    let categories = CategoryLegend.categories
    for first in categories {
      for second in categories where first.index < second.index {
        let distance = first.color(darkMode: darkMode)
          .distance(to: second.color(darkMode: darkMode))
        #expect(distance >= 15, "\(first) vs \(second): ΔE \(distance)")
      }
    }
  }

  @Test func categoryColorsFollowAppleStorage() {
    #expect(FileCategory.documents.color(darkMode: false) == MapPalette.red(darkMode: false))
    #expect(FileCategory.images.color(darkMode: false) == MapPalette.orange(darkMode: false))
    #expect(FileCategory.audio.color(darkMode: false) == MapPalette.yellow(darkMode: false))
    #expect(FileCategory.code.color(darkMode: false) == MapPalette.teal(darkMode: false))
    #expect(FileCategory.apps.color(darkMode: false) == MapPalette.purple(darkMode: false))
    #expect(FileCategory.video.color(darkMode: false) == MapPalette.pink(darkMode: false))
    #expect(FileCategory.archives.color(darkMode: false) == MapPalette.green(darkMode: false))
    #expect(FileCategory.other.color(darkMode: false) == MapPalette.gray(darkMode: false))
  }

  @Test func hsbConversion() {
    #expect(RGBColor(hue: 0, saturation: 1, brightness: 1) == RGBColor(red: 1, green: 0, blue: 0))
    let green = RGBColor(hue: 1.0 / 3, saturation: 1, brightness: 1)
    #expect(abs(green.green - 1) < 1e-9 && green.red < 1e-9 && green.blue < 1e-9)
    #expect(
      RGBColor(hue: 0.5, saturation: 0, brightness: 0.5)
        == RGBColor(red: 0.5, green: 0.5, blue: 0.5))
  }

  @Test func byteFormatUsesFileStyle() {
    #expect(ByteFormat.string(0).contains("0") || ByteFormat.string(0).contains("Zero"))
    #expect(ByteFormat.string(1_500_000).contains("MB"))
  }
}

@Suite struct MapPaletteTests {
  @Test func appleValuesMatchTheSystemColors() {
    #expect(
      MapPalette.red(darkMode: false) == RGBColor(red: 1, green: 0x3b / 255, blue: 0x30 / 255))
    #expect(MapPalette.red(darkMode: true) == RGBColor(red: 1, green: 0x45 / 255, blue: 0x3a / 255))
    #expect(MapPalette.gray(darkMode: false) == RGBColor(hex: 0x8e8e93))
    #expect(MapPalette.white == RGBColor(red: 1, green: 1, blue: 1))
    #expect(MapPalette.black == RGBColor(red: 0, green: 0, blue: 0))
  }

  @Test func mixingMovesBetweenColors() {
    #expect(MapPalette.black.mixed(with: MapPalette.white, by: 0) == MapPalette.black)
    #expect(MapPalette.black.mixed(with: MapPalette.white, by: 1) == MapPalette.white)
    #expect(MapPalette.black.mixed(with: MapPalette.white, by: 2) == MapPalette.white)
    #expect(
      MapPalette.black.mixed(with: MapPalette.white, by: 0.5)
        == RGBColor(red: 0.5, green: 0.5, blue: 0.5))
  }

  @Test func labMatchesKnownValues() {
    let white = MapPalette.white.lab
    #expect(abs(white.l - 100) < 0.01 && abs(white.a) < 0.01 && abs(white.b) < 0.01)
    let black = MapPalette.black.lab
    #expect(abs(black.l) < 0.01)
    // sRGB red is about L 53.2, a 80.1, b 67.2.
    let red = RGBColor(red: 1, green: 0, blue: 0).lab
    #expect(abs(red.l - 53.24) < 0.1 && abs(red.a - 80.09) < 0.2 && abs(red.b - 67.20) < 0.2)
  }

  @Test func distanceIsSymmetricAndZeroForSameColor() {
    let red = MapPalette.red(darkMode: false)
    let orange = MapPalette.orange(darkMode: false)
    #expect(red.distance(to: red) == 0)
    #expect(red.distance(to: orange) == orange.distance(to: red))
    #expect(abs(MapPalette.black.distance(to: MapPalette.white) - 100) < 0.01)
  }

  @Test func labelColorFollowsContrast() {
    #expect(MapPalette.black.prefersLightText)
    #expect(!MapPalette.white.prefersLightText)
    #expect(!MapPalette.gray(darkMode: false).prefersLightText)
    #expect(MapPalette.white.luminance == 1)
    #expect(MapPalette.black.luminance == 0)
    #expect(MapPalette.black.labelColor == MapPalette.white)
    #expect(MapPalette.white.labelColor == MapPalette.darkLabel)
    #expect(MapPalette.gray(darkMode: false).labelColor == MapPalette.darkLabel)
  }

  @Test func contrastRatioMatchesWCAG() {
    #expect(abs(MapPalette.black.contrastRatio(with: MapPalette.white) - 21) < 0.001)
    let red = MapPalette.red(darkMode: false)
    #expect(red.contrastRatio(with: red) == 1)
    #expect(red.contrastRatio(with: MapPalette.white) == MapPalette.white.contrastRatio(with: red))
  }

  /// Map labels are small (10pt), so every category fill and folder fill needs 4.5:1 with its
  /// label color at every shaded depth, in light and dark mode.
  @Test(arguments: [false, true])
  func labelsHaveEnoughContrastOnEveryFill(darkMode: Bool) {
    var fills = FileCategory.allCases.map { $0.color(darkMode: darkMode) }
    for depth in 0...MapPalette.maxShadedDepth {
      fills.append(MapPalette.folderFill(depth: depth, darkMode: darkMode))
    }
    for fill in fills {
      let ratio = fill.labelColor.contrastRatio(with: fill)
      #expect(ratio >= 4.5, "\(fill) has contrast \(ratio)")
    }
  }
}
