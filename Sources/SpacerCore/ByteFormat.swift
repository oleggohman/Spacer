import Foundation

/// Formats byte counts the way Finder does (decimal units, file style).
public enum ByteFormat {
  public static func string(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
