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

@Suite struct CategoryStatsTests {
  @Test func emptyStatsHaveNoDominantCategory() {
    let stats = CategoryStats()
    #expect(stats.total == 0)
    #expect(stats.dominant == nil)
    #expect(FileCategory.allCases.allSatisfy { stats[$0] == 0 })
    #expect(folder("empty", []).dominantCategory == nil)
  }

  @Test func eachCategoryHasItsOwnInlineSlot() {
    var stats = CategoryStats()
    for (index, category) in FileCategory.allCases.enumerated() {
      stats[category] = Int64(index + 1)
    }
    for (index, category) in FileCategory.allCases.enumerated() {
      #expect(stats[category] == Int64(index + 1))
    }
    #expect(stats.total == 45)
    // One Int64 per category and no heap storage, so the layout stays fixed.
    #expect(MemoryLayout<CategoryStats>.size == FileCategory.count * 8)
  }

  @Test func equalityComparesEveryCategory() {
    #expect(CategoryStats() == CategoryStats())
    #expect(CategoryStats(.other, bytes: 1) != CategoryStats(.folders, bytes: 1))
    #expect(CategoryStats(.other, bytes: 1) != CategoryStats(.other, bytes: 2))
    #expect(CategoryStats(.other, bytes: 0) == CategoryStats())
  }

  @Test func addAndSubtractPerCategory() {
    var stats = CategoryStats(.video, bytes: 10)
    stats.add(CategoryStats(.audio, bytes: 5))
    stats.add(CategoryStats(.video, bytes: 1))
    #expect(stats[.video] == 11)
    #expect(stats[.audio] == 5)
    #expect(stats.total == 16)
    stats.subtract(CategoryStats(.video, bytes: 11))
    #expect(stats[.video] == 0)
    #expect(stats.dominant == .audio)
  }

  @Test func fileStatsHoldItsOwnSize() {
    let movie = file("a.mov", 300)
    #expect(movie.categoryStats[.video] == 300)
    #expect(movie.categoryStats.total == 300)
    #expect(movie.dominantCategory == .video)
  }

  @Test func dominantCategoryOfAMixedFolder() {
    let root = folder(
      "mixed",
      [
        file("a.mov", 300), file("b.mp3", 200), file("c.mp3", 150),
        folder("pics", [file("d.jpg", 100), file("e.png", 120)]),
        file("notes", 50),
      ])
    let stats = root.categoryStats
    #expect(stats[.video] == 300)
    #expect(stats[.audio] == 350)
    #expect(stats[.images] == 220)
    #expect(stats[.other] == 50)
    #expect(stats[.folders] == 0)
    #expect(stats.total == root.size)
    #expect(root.dominantCategory == .audio)
    #expect(root.children.first { $0.name == "pics" }?.dominantCategory == .images)
  }

  @Test func aTiePicksTheFirstCategoryInOrder() {
    // Same bytes in both; the winner must not depend on child order.
    let one = folder("one", [file("a.zip", 100), file("b.mov", 100)])
    let two = folder("two", [file("b.mov", 100), file("a.zip", 100)])
    #expect(one.dominantCategory == .video)
    #expect(two.dominantCategory == .video)
    var stats = CategoryStats(.other, bytes: 7)
    stats.add(CategoryStats(.code, bytes: 7))
    #expect(stats.dominant == .code)
  }

  @Test func categoryIndexMatchesAllCasesOrder() {
    for (position, category) in FileCategory.allCases.enumerated() {
      #expect(category.index == position)
      #expect(FileCategory.ordered[category.index] == category)
    }
    #expect(FileCategory.count == FileCategory.allCases.count)
  }

  @Test func addingIntoEmptyAndSubtractingFromEmptyStats() {
    var empty = CategoryStats()
    empty.add(CategoryStats())
    #expect(empty == CategoryStats())
    empty.add(CategoryStats(.code, bytes: 3))
    #expect(empty == CategoryStats(.code, bytes: 3))
    var negative = CategoryStats()
    negative.subtract(CategoryStats(.code, bytes: 3))
    #expect(negative[.code] == -3)
    negative.subtract(CategoryStats())
    #expect(negative.total == -3)
  }

  @Test func appBundleShowsItsContentButCountsAsAnAppInItsParent() {
    let app = folder(
      "Tool.app", [file("icon.png", 500), file("Tool", 100)], isPackage: true)
    let apps = folder("Applications", [app, file("readme.txt", 50)])
    #expect(app.isAppBundle)
    #expect(!apps.isAppBundle)
    // Inside the bundle: what it is made of.
    #expect(app.categoryStats[.images] == 500)
    #expect(app.categoryStats[.other] == 100)
    #expect(app.categoryStats[.apps] == 0)
    #expect(app.categoryStats.total == app.size)
    #expect(app.dominantCategory == .images)
    // The bundle itself is still drawn as an app.
    #expect(app.colorCategory == .apps)
    // In its parent: one app.
    #expect(apps.categoryStats[.apps] == 600)
    #expect(apps.categoryStats[.images] == 0)
    #expect(apps.categoryStats[.documents] == 50)
    #expect(apps.categoryStats.total == apps.size)
    #expect(apps.dominantCategory == .apps)
    #expect(apps.colorCategory == .apps)
  }

  @Test func colorCategoryOfFilesFoldersAndEmptyFolders() {
    #expect(file("a.mov", 1).colorCategory == .video)
    #expect(folder("v", [file("a.mov", 1)]).colorCategory == .video)
    #expect(folder("empty", []).colorCategory == .folders)
  }

  @Test func statsStayRightAfterRemove() throws {
    let movies = folder("movies", [file("a.mov", 300), file("b.mov", 200)])
    let root = folder("root", [movies, file("c.mp3", 400)])
    #expect(root.dominantCategory == .video)

    let a = try #require(movies.children.first { $0.name == "a.mov" })
    a.remove()
    #expect(movies.categoryStats[.video] == 200)
    #expect(root.categoryStats[.video] == 200)
    #expect(root.categoryStats.total == root.size)
    #expect(root.dominantCategory == .audio)

    movies.remove()
    #expect(root.categoryStats[.video] == 0)
    #expect(root.categoryStats.total == 400)
  }

  /// Every folder's stats add up to its size, from `node` up to the root.
  private func expectStatsMatchSizes(from node: FileNode) {
    for ancestor in node.ancestry {
      #expect(ancestor.categoryStats.total == ancestor.size, "\(ancestor.name)")
    }
  }

  @Test func removingFromAnAppBundleKeepsItAnAppInItsParent() throws {
    let app = folder("Tool.app", [file("icon.png", 500), file("Tool", 100)], isPackage: true)
    let root = folder("root", [app])
    let icon = try #require(app.children.first { $0.name == "icon.png" })
    icon.remove()
    #expect(app.categoryStats[.images] == 0)
    #expect(app.categoryStats[.other] == 100)
    #expect(root.categoryStats[.apps] == 100)
    #expect(root.categoryStats[.images] == 0)
    expectStatsMatchSizes(from: app)
  }

  @Test func removingAWholeAppBundleFromAPlainFolder() throws {
    let app = folder("Tool.app", [file("icon.png", 500)], isPackage: true)
    let apps = folder("Applications", [app, file("readme.txt", 50)])
    let root = folder("root", [apps, file("a.mov", 10)])
    app.remove()
    #expect(apps.categoryStats[.apps] == 0)
    #expect(apps.categoryStats[.images] == 0)
    #expect(root.categoryStats[.apps] == 0)
    #expect(root.categoryStats[.documents] == 50)
    #expect(root.dominantCategory == .documents)
    expectStatsMatchSizes(from: apps)
  }

  @Test func removingFromASubfolderInsideABundle() throws {
    let contents = folder("Contents", [file("x.png", 300), file("Info.plist", 20)])
    let app = folder("Tool.app", [contents], isPackage: true)
    let root = folder("root", [app, file("a.mov", 100)])
    let png = try #require(contents.children.first { $0.name == "x.png" })
    png.remove()
    #expect(contents.categoryStats[.images] == 0)
    #expect(app.categoryStats[.images] == 0)
    #expect(root.categoryStats[.apps] == 20)
    #expect(root.categoryStats[.images] == 0)
    #expect(root.dominantCategory == .video)
    expectStatsMatchSizes(from: contents)
  }

  @Test func removingFromANestedBundle() throws {
    let helper = folder("Helper.app", [file("h.png", 200), file("Helper", 50)], isPackage: true)
    let outer = folder("Outer.app", [helper, file("o.swift", 30)], isPackage: true)
    let root = folder("root", [outer])
    #expect(outer.categoryStats[.apps] == 250)
    #expect(outer.categoryStats[.code] == 30)
    #expect(root.categoryStats[.apps] == 280)
    let png = try #require(helper.children.first { $0.name == "h.png" })
    png.remove()
    #expect(helper.categoryStats[.images] == 0)
    #expect(helper.categoryStats[.other] == 50)
    #expect(outer.categoryStats[.apps] == 50)
    #expect(outer.categoryStats[.code] == 30)
    #expect(root.categoryStats[.apps] == 80)
    expectStatsMatchSizes(from: helper)
    helper.remove()
    #expect(outer.categoryStats[.apps] == 0)
    #expect(root.categoryStats[.apps] == 30)
    expectStatsMatchSizes(from: outer)
  }

  @Test func previewAppBundleCountsItsWholeSizeInItsParent() {
    // A preview bundle's size includes content it does not list.
    let app = FileNode(
      name: "X.app", url: URL(fileURLWithPath: "/scan/X.app", isDirectory: true),
      children: [file("x.png", 10)], size: 1000, isPackage: true)
    let apps = folder("Applications", [app])
    #expect(app.categoryStats.total == 10)
    #expect(CategoryLegend(for: app).unlisted == 990)
    #expect(apps.categoryStats[.apps] == 1000)
    #expect(apps.categoryStats.total == apps.size)
    #expect(CategoryLegend(for: apps).unlisted == 0)
  }

  @Test func previewFolderCountsOnlyListedFiles() {
    // A preview folder's size includes bytes it does not list.
    let partial = FileNode(
      name: "partial", url: URL(fileURLWithPath: "/scan/partial", isDirectory: true),
      children: [file("a.mov", 10)], size: 1000)
    let summary = FileNode(
      name: "summary", url: URL(fileURLWithPath: "/scan/summary", isDirectory: true),
      children: [], size: 1000)
    #expect(partial.categoryStats.total == 10)
    #expect(partial.dominantCategory == .video)
    #expect(summary.dominantCategory == nil)
    #expect(
      FileCategory.fill(for: summary, depth: 1, darkMode: false)
        == MapPalette.folderFill(depth: 1, darkMode: false))
  }

  @Test func unknownExtensionsAreCachedConsistently() {
    #expect(FileCategory.of(extension: "qzxv") == FileCategory.of(extension: "QZXV"))
    #expect(FileCategory.of(extension: "qzxv") == .other)
    #expect(FileCategory.cachedSystemType("qzxv") == .other)
    // "m2ts" is not in the table: the first call asks the system, the second uses the cache.
    let direct = FileCategory.ofSystemType(extension: "m2ts")
    #expect(direct == .video)
    #expect(FileCategory.of(extension: "m2ts") == direct)
    #expect(FileCategory.cachedSystemType("m2ts") == direct)
    #expect(FileCategory.of(extension: "M2TS") == direct)
  }

  @Test func systemTypeCacheStopsGrowingAtItsLimit() {
    var cache: [String: FileCategory] = [:]
    FileCategory.remember(.video, for: "a", in: &cache, limit: 2)
    FileCategory.remember(.audio, for: "b", in: &cache, limit: 2)
    FileCategory.remember(.images, for: "c", in: &cache, limit: 2)
    #expect(cache == ["a": .video, "b": .audio])
    #expect(FileCategory.systemTypeCacheLimit == 4096)
  }
}

@Suite struct FolderFillTests {
  @Test func fillUsesCategoryColorForFilesAndAppsAndFolderFillForFolders() {
    let movie = file("a.mov", 10)
    #expect(
      FileCategory.fill(for: movie, depth: 2, darkMode: false)
        == FileCategory.video.color(darkMode: false))
    let app = folder("X.app", [file("x.png", 10)], isPackage: true)
    #expect(
      FileCategory.fill(for: app, depth: 0, darkMode: true)
        == FileCategory.apps.color(darkMode: true))
    let videos = folder("v", [movie])
    #expect(
      FileCategory.fill(for: videos, depth: 0, darkMode: false)
        == MapPalette.folderFill(depth: 0, darkMode: false))
  }
}
