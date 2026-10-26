import Foundation

/// The line above the map: how big the scan is, the volume it is measured against, and how old
/// it is. Also the "Why different?" text.
public struct ScanSummary: Sendable {
  /// The scanned size, e.g. "699.8 GB".
  public let sizeText: String
  /// The volume whose root was scanned. Nil for a folder scan.
  public let volume: VolumeInfo?
  /// "of 699.8 GB used on Macintosh HD · scanned 2 min ago" for a volume, "scanned 2 min ago"
  /// for a folder. The age is left out when the scan has not finished.
  public let detailText: String
  /// True when some folders could not be read, so the total is short.
  public let isIncomplete: Bool

  public init(
    root: FileNode, scanURL: URL, volumes: [VolumeInfo], finishedAt: Date?, now: Date = Date(),
    unreadableCount: Int = 0
  ) {
    let path = scanURL.standardizedFileURL.path
    let volume = volumes.first { $0.url.standardizedFileURL.path == path }
    var parts: [String] = []
    if let volume {
      parts.append("of \(ByteFormat.string(volume.usedCapacity)) used on \(volume.name)")
    }
    if let finishedAt {
      parts.append(ScanAge.text(finished: finishedAt, now: now))
    }
    self.sizeText = ByteFormat.string(root.size)
    self.volume = volume
    self.detailText = parts.joined(separator: " · ")
    self.isIncomplete = unreadableCount > 0 || root.accessDenied
  }

  /// The explanation behind "Why different?": why the map total can be smaller than the used
  /// space. With unreadable folders, a second line counts them.
  public func whyDifferentText(unreadableCount: Int) -> String {
    let base =
      "Spacer counts the files it can read. The rest is APFS snapshots, purgeable space, system data, and folders Spacer couldn't read."
    guard unreadableCount > 0 else { return base }
    let noun = unreadableCount == 1 ? "folder" : "folders"
    return base + "\n\(unreadableCount.formatted()) \(noun) couldn't be read."
  }
}

/// How long ago a scan finished, in words.
public enum ScanAge {
  /// "scanned just now", "scanned 5 min ago", "scanned 1 hr ago", "scanned yesterday at 14:02",
  /// "scanned 4 days ago".
  public static func text(finished: Date, now: Date = Date()) -> String {
    let age = now.timeIntervalSince(finished)
    if age < 60 { return "scanned just now" }
    if age < 3_600 { return "scanned \(Int(age / 60)) min ago" }
    if age < 86_400 {
      let hours = Int(age / 3_600)
      return hours == 1 ? "scanned 1 hr ago" : "scanned \(hours) hr ago"
    }
    if age < 2 * 86_400 {
      return "scanned yesterday at \(finished.formatted(date: .omitted, time: .shortened))"
    }
    return "scanned \(Int(age / 86_400)) days ago"
  }

  /// True once the scan is more than an hour old. The view shows the age in orange then.
  public static func isStale(finished: Date, now: Date = Date()) -> Bool {
    now.timeIntervalSince(finished) > 3_600
  }
}

/// The version line at the bottom of the sidebar.
public enum AppVersion {
  /// "Spacer 0.2.0 (build 7)", "Spacer 0.2.0" without a build, and "Spacer (development build)"
  /// without a version (a plain `swift run` has no bundle version).
  public static func footerText(version: String?, build: String?) -> String {
    guard let version, !version.isEmpty else { return "Spacer (development build)" }
    guard let build, !build.isEmpty else { return "Spacer \(version)" }
    return "Spacer \(version) (build \(build))"
  }
}
