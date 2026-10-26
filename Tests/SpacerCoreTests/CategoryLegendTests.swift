import Foundation
import Testing

@testable import SpacerCore

private func file(_ path: String, _ size: Int64) -> FileNode {
  FileNode(name: path, url: URL(fileURLWithPath: "/scan/\(path)"), size: size)
}

private func folder(_ path: String, _ children: [FileNode], isPackage: Bool = false) -> FileNode {
  FileNode(
    name: path, url: URL(fileURLWithPath: "/scan/\(path)", isDirectory: true),
    children: children, isPackage: isPackage)
}

private func mixedFolder() -> FileNode {
  folder(
    "mixed",
    [
      file("a.mov", 300), file("b.mp3", 200), file("c.swift", 50),
      folder("pics", [file("d.jpg", 100), file("e.png", 120)]),
      folder("Tool.app", [file("Tool", 80)], isPackage: true),
      file("notes", 150),
    ])
}

@Suite struct CategoryLegendTests {
  @Test func everyCategoryHasADistinctDisplayName() {
    let names = FileCategory.allCases.map(\.displayName)
    #expect(names.allSatisfy { !$0.isEmpty && $0.first!.isUppercase })
    #expect(Set(names).count == FileCategory.allCases.count)
    #expect(FileCategory.video.displayName == "Video")
    #expect(FileCategory.other.displayName == "Other")
    #expect(FileCategory.folders.displayName == "Folders")
    #expect(FileCategory.images.displayName == "Photos")
    #expect(FileCategory.audio.displayName == "Music")
    #expect(FileCategory.code.displayName == "Developer")
  }

  @Test func legendListsEveryCategoryButFolders() {
    #expect(CategoryLegend.categories == FileCategory.allCases.filter { $0 != .folders })
    let legend = CategoryLegend(for: mixedFolder())
    #expect(legend.shares.map(\.category) == CategoryLegend.categories)
  }

  @Test func sharesAddUpToTheFolderSize() {
    let root = mixedFolder()
    let legend = CategoryLegend(for: root)
    #expect(legend.shares.reduce(0) { $0 + $1.bytes } + legend.unlisted == root.size)
    #expect(legend.unlisted == 0)
    #expect(abs(legend.shares.reduce(0) { $0 + $1.fraction } - 1) < 1e-9)
    let bytes = Dictionary(uniqueKeysWithValues: legend.shares.map { ($0.category, $0.bytes) })
    #expect(bytes[.video] == 300)
    #expect(bytes[.audio] == 200)
    #expect(bytes[.images] == 220)
    #expect(bytes[.code] == 50)
    #expect(bytes[.apps] == 80)
    #expect(bytes[.other] == 150)
    #expect(bytes[.documents] == 0)
  }

  @Test func sharesOfASubfolderAddUpToItsSize() {
    let pics = mixedFolder().children.first { $0.name == "pics" }!
    let legend = CategoryLegend(for: pics)
    #expect(legend.shares.reduce(0) { $0 + $1.bytes } == pics.size)
    #expect(legend.shares.first { $0.category == .images }?.fraction == 1)
  }

  @Test func previewFolderCountsUnlistedBytes() {
    let preview = FileNode(
      name: "preview", url: URL(fileURLWithPath: "/scan/preview", isDirectory: true),
      children: [file("a.mov", 300), file("b.mp3", 100)], size: 1000)
    let legend = CategoryLegend(for: preview)
    #expect(legend.unlisted == 600)
    #expect(legend.shares.reduce(0) { $0 + $1.bytes } + legend.unlisted == preview.size)
    #expect(legend.shares.first { $0.category == .video }?.percentText == "30%")
    #expect(legend.unlistedPercentText == "60%")
  }

  @Test func emptyFolderHasZeroShares() {
    let legend = CategoryLegend(for: folder("empty", []))
    #expect(legend.shares.allSatisfy { $0.bytes == 0 && $0.fraction == 0 && $0.percentText == "" })
    #expect(legend.unlisted == 0)
    #expect(legend.unlistedPercentText == "")
  }

  @Test func percentTextRoundsAndMarksTinyShares() {
    #expect(CategoryShare(category: .code, bytes: 1, fraction: 0.001).percentText == "<1%")
    #expect(CategoryShare(category: .code, bytes: 5, fraction: 0.426).percentText == "43%")
    #expect(CategoryShare(category: .code, bytes: 5, fraction: 0.424).percentText == "42%")
    #expect(CategoryShare(category: .code, bytes: 10, fraction: 1).percentText == "100%")
    #expect(CategoryShare(category: .code, bytes: 0, fraction: 0).percentText == "")
  }

  @Test func onlyCategoriesTheFolderHoldsCanBeHighlighted() {
    let legend = CategoryLegend(for: mixedFolder())
    let enabled = Set(legend.shares.filter(\.canHighlight).map(\.category))
    #expect(enabled == [.video, .audio, .images, .code, .apps, .other])
  }

  @Test func legendOfApplicationsCountsBundlesAsAppsAndABundleShowsItsContent() throws {
    let xcode = folder(
      "Xcode.app",
      [file("lib.dylib", 300), file("icon.png", 100), file("Xcode", 50)], isPackage: true)
    let apps = folder("Applications", [xcode, file("readme.txt", 50)])
    let outer = CategoryLegend(for: apps)
    #expect(outer.shares.first { $0.category == .apps }?.bytes == 450)
    #expect(outer.shares.first { $0.category == .code }?.canHighlight == false)
    let inner = CategoryLegend(for: xcode)
    #expect(inner.shares.first { $0.category == .code }?.bytes == 300)
    #expect(inner.shares.first { $0.category == .apps }?.canHighlight == false)
    #expect(inner.shares.reduce(0) { $0 + $1.bytes } == xcode.size)
  }
}

@Suite struct CategoryHighlightTests {
  private func rect(_ node: FileNode, _ kind: TreemapRect.Kind = .block) -> TreemapRect {
    TreemapRect(node: node, rect: .zero, depth: 1, kind: kind)
  }

  @Test func filesMatchTheirOwnCategory() {
    let movie = file("a.mov", 10)
    let root = folder("root", [movie])
    #expect(CategoryHighlight.matches(rect(movie), category: .video, root: root))
    #expect(!CategoryHighlight.matches(rect(movie), category: .audio, root: root))
  }

  @Test func appBundleBlockMatchesApps() {
    let app = folder("Tool.app", [file("Tool", 80)], isPackage: true)
    let root = folder("root", [app])
    #expect(CategoryHighlight.matches(rect(app), category: .apps, root: root))
    #expect(!CategoryHighlight.matches(rect(app), category: .other, root: root))
  }

  @Test func folderBlocksAndSmallItemsMatchTheirDominantCategory() {
    let root = mixedFolder()
    let pics = root.children.first { $0.name == "pics" }!
    #expect(CategoryHighlight.matches(rect(pics), category: .images, root: root))
    #expect(!CategoryHighlight.matches(rect(pics), category: .video, root: root))
    let small = rect(root, .smallItems(count: 3, size: 10))
    #expect(CategoryHighlight.matches(small, category: .video, root: root))
    #expect(!CategoryHighlight.matches(small, category: .images, root: root))
  }

  @Test func headersMatchAnyCategoryTheFolderHolds() {
    let root = mixedFolder()
    let header = rect(root, .folderHeader)
    #expect(CategoryHighlight.matches(header, category: .video, root: root))
    #expect(CategoryHighlight.matches(header, category: .code, root: root))
    #expect(CategoryHighlight.matches(header, category: .apps, root: root))
    #expect(!CategoryHighlight.matches(header, category: .documents, root: root))
    // The folder's own block (under the header) only matches its dominant category.
    #expect(CategoryHighlight.matches(rect(root), category: .video, root: root))
    #expect(!CategoryHighlight.matches(rect(root), category: .code, root: root))
  }

  /// /Applications/Xcode.app/{Contents/{lib.dylib, icon.png}, Xcode} and a top-level movie.
  private func applications() -> (apps: FileNode, xcode: FileNode, contents: FileNode) {
    let contents = folder("Contents", [file("lib.dylib", 300), file("icon.png", 100)])
    let xcode = folder("Xcode.app", [contents, file("Xcode", 50)], isPackage: true)
    let apps = folder("Applications", [xcode, file("intro.mov", 20)])
    return (apps, xcode, contents)
  }

  @Test func everythingInsideABundleBelowTheRootCountsAsApps() throws {
    let (apps, xcode, contents) = applications()
    let dylib = try #require(contents.children.first { $0.name == "lib.dylib" })
    let inBundle = [
      rect(xcode), rect(xcode, .folderHeader), rect(contents), rect(contents, .folderHeader),
      rect(dylib), rect(contents, .smallItems(count: 2, size: 5)),
    ]
    for item in inBundle {
      #expect(CategoryHighlight.matches(item, category: .apps, root: apps), "\(item.node.name)")
      #expect(!CategoryHighlight.matches(item, category: .code, root: apps), "\(item.node.name)")
    }
    // The legend of /Applications agrees: the bundle's bytes are all apps, none are code.
    let legend = CategoryLegend(for: apps)
    #expect(legend.shares.first { $0.category == .apps }?.bytes == xcode.size)
    #expect(legend.shares.first { $0.category == .code }?.bytes == 0)
  }

  @Test func insideABundleThatIsTheRootItemsMatchByContent() throws {
    let (_, xcode, contents) = applications()
    let dylib = try #require(contents.children.first { $0.name == "lib.dylib" })
    let png = try #require(contents.children.first { $0.name == "icon.png" })
    #expect(CategoryHighlight.matches(rect(dylib), category: .code, root: xcode))
    #expect(!CategoryHighlight.matches(rect(dylib), category: .apps, root: xcode))
    #expect(!CategoryHighlight.matches(rect(png), category: .code, root: xcode))
    #expect(CategoryHighlight.matches(rect(contents), category: .code, root: xcode))
    #expect(
      CategoryHighlight.matches(rect(contents, .folderHeader), category: .images, root: xcode))
    // The root bundle's header shows the path to its content, like any folder's.
    #expect(CategoryHighlight.matches(rect(xcode, .folderHeader), category: .code, root: xcode))
    // The legend of the bundle agrees: code is there, apps are not.
    let legend = CategoryLegend(for: xcode)
    #expect(legend.shares.first { $0.category == .code }?.bytes == 300)
    #expect(legend.shares.first { $0.category == .apps }?.bytes == 0)
  }

  @Test(arguments: [false, true])
  func headerTextFollowsItsBlockAndDimsWhenItDoesNotMatch(darkMode: Bool) {
    let root = mixedFolder()
    let header = rect(root, .folderHeader)
    let fill = FileCategory.fill(for: root, depth: 1, darkMode: darkMode)
    let plain = CategoryHighlight.headerText(
      header, fill: fill, highlight: nil, root: root, darkMode: darkMode)
    #expect(plain.color == fill.labelColor && plain.opacity == 1)
    // Video is dominant: the block stays bright and so does the header.
    let video = CategoryHighlight.headerText(
      header, fill: fill, highlight: .video, root: root, darkMode: darkMode)
    #expect(video.color == fill.labelColor && video.opacity == 1)
    // Code is in the folder but not dominant: the block fades, the header text does not dim.
    let faded = CategoryHighlight.faded(fill, darkMode: darkMode)
    let code = CategoryHighlight.headerText(
      header, fill: fill, highlight: .code, root: root, darkMode: darkMode)
    #expect(code.color == faded.labelColor && code.opacity == 1)
    // No documents at all: faded block and dimmed text.
    let documents = CategoryHighlight.headerText(
      header, fill: fill, highlight: .documents, root: root, darkMode: darkMode)
    #expect(documents.color == faded.labelColor)
    #expect(documents.opacity == CategoryHighlight.dimmedHeaderOpacity)
  }

  @Test(arguments: [false, true])
  func fadedColorIsTheExactMixTowardTheBackground(darkMode: Bool) {
    let background = CategoryHighlight.background(darkMode: darkMode)
    #expect(background == MapPalette.background(darkMode: darkMode))
    let color = FileCategory.video.color(darkMode: darkMode)
    let faded = CategoryHighlight.faded(color, darkMode: darkMode)
    #expect(faded == color.mixed(with: background, by: CategoryHighlight.fadeAmount))
    #expect(faded.distance(to: background) < color.distance(to: background))
    #expect([faded.red, faded.green, faded.blue].allSatisfy { (0...1).contains($0) })
  }
}

extension CategoryHighlightTests {
  @Test(arguments: [false, true])
  func shownKeepsMatchesAndFadesTheRest(darkMode: Bool) {
    let movie = file("a.mov", 10)
    let root = folder("root", [movie])
    let fill = FileCategory.fill(for: movie, depth: 1, darkMode: darkMode)
    let block = TreemapRect(node: movie, rect: .zero, depth: 1, kind: .block)
    let plain = CategoryHighlight.shown(
      fill, for: block, highlight: nil, root: root, darkMode: darkMode)
    #expect(plain.color == fill && !plain.faded)
    let match = CategoryHighlight.shown(
      fill, for: block, highlight: .video, root: root, darkMode: darkMode)
    #expect(match.color == fill && !match.faded)
    let other = CategoryHighlight.shown(
      fill, for: block, highlight: .audio, root: root, darkMode: darkMode)
    #expect(other.color == CategoryHighlight.faded(fill, darkMode: darkMode) && other.faded)
    let small = TreemapRect(
      node: root, rect: .zero, depth: 1, kind: .smallItems(count: 2, size: 4))
    #expect(
      !CategoryHighlight.shown(
        fill, for: small, highlight: .video, root: root, darkMode: darkMode
      ).faded)
  }
}

@MainActor @Suite struct HighlightToggleTests {
  @Test func toggleSetsAndClearsTheHighlight() {
    let session = ScanSession()
    #expect(session.highlightedCategory == nil)
    session.toggleHighlight(.video)
    #expect(session.highlightedCategory == .video)
    session.toggleHighlight(.audio)
    #expect(session.highlightedCategory == .audio)
    session.toggleHighlight(.audio)
    #expect(session.highlightedCategory == nil)
  }

  @Test func hidingTheLegendClearsTheHighlight() {
    let session = ScanSession()
    #expect(session.isLegendVisible)
    session.toggleHighlight(.video)
    session.setLegendVisible(true)
    #expect(session.highlightedCategory == .video)
    session.setLegendVisible(false)
    #expect(!session.isLegendVisible)
    #expect(session.highlightedCategory == nil)
    session.setLegendVisible(true)
    #expect(session.isLegendVisible)
  }

  @Test func aNewScanClearsTheHighlight() async throws {
    let tree = try TempTree()
    defer { withExtendedLifetime(tree) {} }
    try tree.file("a.mov", bytes: 4096)
    let session = ScanSession()
    session.toggleHighlight(.video)
    session.start(url: tree.root)
    #expect(session.highlightedCategory == nil)
    await session.waitForScan()
    #expect(session.isLegendVisible)
  }
}
