import Foundation
import Testing

@testable import SpacerCore

@Suite struct DeletionPromptTests {
  @Test func titleCountsItemsAndShowsTheSize() {
    let size = ByteFormat.string(2048)
    #expect(
      DeletionPrompt.title(mode: .moveToTrash, count: 1, size: 2048)
        == "Move 1 item (\(size)) to the Trash?")
    #expect(
      DeletionPrompt.title(mode: .moveToTrash, count: 3, size: 2048)
        == "Move 3 items (\(size)) to the Trash?")
    #expect(
      DeletionPrompt.title(mode: .deletePermanently, count: 2, size: 2048)
        == "Permanently delete 2 items (\(size))?")
  }

  @Test func messageListsEightNamesThenTheRest() {
    let names = (1...10).map { "item\($0)" }
    let message = DeletionPrompt.message(mode: .moveToTrash, names: names)
    #expect(message.split(separator: "\n").count == 9)
    #expect(message.hasPrefix("item1\nitem2"))
    #expect(message.hasSuffix("item8\nand 2 more"))
    #expect(DeletionPrompt.message(mode: .moveToTrash, names: ["a", "b"]) == "a\nb")
  }

  @Test func permanentDeleteWarnsItCannotBeUndone() {
    #expect(
      DeletionPrompt.message(mode: .deletePermanently, names: ["a"])
        == "a\n\nThis cannot be undone.")
  }
}
