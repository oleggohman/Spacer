import Foundation
import Testing

@testable import SpacerCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let macintoshHD = VolumeInfo(
  url: URL(fileURLWithPath: "/"), name: "Macintosh HD", totalCapacity: 500_000_000_000,
  availableCapacity: 120_000_000_000)

/// A root of one 1 GB file, so `sizeText` is "1 GB".
private func makeRoot(accessDenied: Bool = false) -> FileNode {
  let url = URL(fileURLWithPath: "/scan")
  let file = FileNode(
    name: "big.bin", url: url.appendingPathComponent("big.bin"), size: 1_000_000_000)
  return FileNode(name: "scan", url: url, children: [file], accessDenied: accessDenied)
}

@Suite struct ScanSummaryTests {
  @Test func ageTextAtEachStep() {
    #expect(ScanAge.text(finished: now.addingTimeInterval(-10), now: now) == "scanned just now")
    #expect(ScanAge.text(finished: now.addingTimeInterval(-60), now: now) == "scanned 1 min ago")
    #expect(ScanAge.text(finished: now.addingTimeInterval(-300), now: now) == "scanned 5 min ago")
    #expect(ScanAge.text(finished: now.addingTimeInterval(-3_600), now: now) == "scanned 1 hr ago")
    #expect(ScanAge.text(finished: now.addingTimeInterval(-7_200), now: now) == "scanned 2 hr ago")
    #expect(
      ScanAge.text(finished: now.addingTimeInterval(-4 * 86_400), now: now)
        == "scanned 4 days ago")
  }

  @Test func ageTextBoundaries() {
    func text(_ seconds: Double) -> String {
      ScanAge.text(finished: now.addingTimeInterval(-seconds), now: now)
    }
    #expect(text(59) == "scanned just now")
    #expect(text(60) == "scanned 1 min ago")
    #expect(text(3_599) == "scanned 59 min ago")
    #expect(text(3_600) == "scanned 1 hr ago")
    #expect(text(86_399) == "scanned 23 hr ago")
    #expect(text(86_400).hasPrefix("scanned yesterday at "))
    #expect(text(2 * 86_400 - 1).hasPrefix("scanned yesterday at "))
    #expect(text(2 * 86_400) == "scanned 2 days ago")
  }

  @Test func ageTextFromYesterdayGivesTheTime() {
    let finished = now.addingTimeInterval(-30 * 3_600)
    let text = ScanAge.text(finished: finished, now: now)
    let time = finished.formatted(date: .omitted, time: .shortened)
    #expect(text == "scanned yesterday at \(time)")
  }

  @Test func ageIsJustNowForAFutureDate() {
    #expect(ScanAge.text(finished: now.addingTimeInterval(120), now: now) == "scanned just now")
  }

  @Test func staleAfterAnHour() {
    #expect(!ScanAge.isStale(finished: now.addingTimeInterval(-3_599), now: now))
    #expect(!ScanAge.isStale(finished: now.addingTimeInterval(-3_600), now: now))
    #expect(ScanAge.isStale(finished: now.addingTimeInterval(-3_601), now: now))
  }

  @Test func volumeSummaryNamesTheVolumeAndTheAge() {
    let summary = ScanSummary(
      root: makeRoot(), scanURL: URL(fileURLWithPath: "/"), volumes: [macintoshHD],
      finishedAt: now.addingTimeInterval(-120), now: now)
    #expect(summary.sizeText == ByteFormat.string(1_000_000_000))
    #expect(summary.volume == macintoshHD)
    #expect(
      summary.detailText
        == "of \(ByteFormat.string(380_000_000_000)) used on Macintosh HD · scanned 2 min ago")
    #expect(!summary.isIncomplete)
  }

  @Test func folderSummaryHasNoVolumeText() {
    let summary = ScanSummary(
      root: makeRoot(), scanURL: URL(fileURLWithPath: "/scan"), volumes: [macintoshHD],
      finishedAt: now.addingTimeInterval(-120), now: now)
    #expect(summary.volume == nil)
    #expect(summary.detailText == "scanned 2 min ago")
  }

  @Test func volumeSummaryWithoutFinishTimeHasNoAge() {
    let summary = ScanSummary(
      root: makeRoot(), scanURL: URL(fileURLWithPath: "/"), volumes: [macintoshHD],
      finishedAt: nil, now: now)
    #expect(
      summary.detailText == "of \(ByteFormat.string(380_000_000_000)) used on Macintosh HD")
  }

  @Test func folderSummaryWithoutFinishTimeIsEmpty() {
    let summary = ScanSummary(
      root: makeRoot(), scanURL: URL(fileURLWithPath: "/scan"), volumes: [],
      finishedAt: nil, now: now)
    #expect(summary.detailText.isEmpty)
  }

  @Test func incompleteWhenFoldersOrTheRootCouldNotBeRead() {
    let url = URL(fileURLWithPath: "/scan")
    let plain = ScanSummary(
      root: makeRoot(), scanURL: url, volumes: [], finishedAt: nil, unreadableCount: 0)
    let withFolders = ScanSummary(
      root: makeRoot(), scanURL: url, volumes: [], finishedAt: nil, unreadableCount: 3)
    let rootDenied = ScanSummary(
      root: makeRoot(accessDenied: true), scanURL: url, volumes: [], finishedAt: nil)
    #expect(!plain.isIncomplete)
    #expect(withFolders.isIncomplete)
    #expect(rootDenied.isIncomplete)
  }

  @Test func whyDifferentTextCountsUnreadableFolders() {
    let summary = ScanSummary(
      root: makeRoot(), scanURL: URL(fileURLWithPath: "/"), volumes: [], finishedAt: nil)
    let base =
      "Spacer counts the files it can read. The rest is APFS snapshots, purgeable space, system data, and folders Spacer couldn't read."
    #expect(summary.whyDifferentText(unreadableCount: 0) == base)
    #expect(
      summary.whyDifferentText(unreadableCount: 3) == base + "\n3 folders couldn't be read.")
    #expect(
      summary.whyDifferentText(unreadableCount: 1) == base + "\n1 folder couldn't be read.")
  }

  @Test func warningsGroupLargeCounts() {
    #expect(
      UnreadableFolders.warningText(count: 1_200, rootDenied: false, hasFullDiskAccess: false)
        == "\(1_200.formatted()) folders couldn't be read. Grant Full Disk Access")
    #expect(
      UnreadableFolders.warningText(count: 1, rootDenied: false, hasFullDiskAccess: false)
        == "1 folder couldn't be read. Grant Full Disk Access")
    #expect(
      UnreadableFolders.warningText(count: 1_200, rootDenied: false, hasFullDiskAccess: true)
        == "\(1_200.formatted()) folders couldn't be read. macOS protects them, "
        + "so their size isn't counted.")
    let summary = ScanSummary(
      root: makeRoot(), scanURL: URL(fileURLWithPath: "/"), volumes: [], finishedAt: nil)
    #expect(
      summary.whyDifferentText(unreadableCount: 1_200).hasSuffix(
        "\n\(1_200.formatted()) folders couldn't be read."))
  }

  @Test func appVersionFooterHasVersionAndBuild() {
    #expect(AppVersion.footerText(version: "0.2.0", build: "7") == "Spacer 0.2.0 (build 7)")
    #expect(AppVersion.footerText(version: "0.2.0", build: nil) == "Spacer 0.2.0")
    #expect(AppVersion.footerText(version: "0.2.0", build: "") == "Spacer 0.2.0")
    #expect(AppVersion.footerText(version: nil, build: "7") == "Spacer (development build)")
    #expect(AppVersion.footerText(version: "", build: nil) == "Spacer (development build)")
  }
}
