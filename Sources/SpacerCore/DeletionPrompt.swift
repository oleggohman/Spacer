import Foundation

/// The texts of the delete confirmation: a title with the item count and size, and a message
/// listing the items.
public enum DeletionPrompt {
  /// The most item names the message lists before it says "and N more".
  static let maxNames = 8

  /// "Move 3 items (1.2 GB) to the Trash?" or "Permanently delete 1 item (4 KB)?".
  public static func title(mode: DeletionMode, count: Int, size: Int64) -> String {
    let noun = count == 1 ? "item" : "items"
    let size = ByteFormat.string(size)
    return mode == .deletePermanently
      ? "Permanently delete \(count) \(noun) (\(size))?"
      : "Move \(count) \(noun) (\(size)) to the Trash?"
  }

  /// The names of the items as given, then "and N more", and for a permanent delete a note that
  /// it cannot be undone.
  public static func message(mode: DeletionMode, names: [String]) -> String {
    var lines = Array(names.prefix(maxNames))
    if names.count > lines.count { lines.append("and \(names.count - lines.count) more") }
    if mode == .deletePermanently { lines.append("\nThis cannot be undone.") }
    return lines.joined(separator: "\n")
  }
}
