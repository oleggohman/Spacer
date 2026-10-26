import AppKit
import SpacerCore
import SwiftUI

@main
struct SpacerApp: App {
  @State private var session = ScanSession()
  @State private var updater = AppUpdater()
  /// Set by the window when the selection can be moved to the Trash.
  @FocusedValue(\.moveToTrash) private var moveToTrash

  var body: some Scene {
    WindowGroup {
      ContentView(session: session)
        .frame(minWidth: 900, minHeight: 560)
    }
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Spacer") { NSApp.orderFrontStandardAboutPanel(nil) }
        if updater.isAvailable {
          Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        }
      }
      CommandGroup(after: .newItem) {
        Button("Move to Trash…") { moveToTrash?.perform() }
          .keyboardShortcut(.delete, modifiers: .command)
          .disabled(moveToTrash == nil)
      }
      CommandGroup(after: .toolbar) {
        Button("Rescan") { session.rescan() }
          .keyboardShortcut("r")
          .disabled(session.scanURL == nil || session.isScanning || session.isDeleting)
        Button("Stop Scan") { session.cancel() }
          .keyboardShortcut(".")
          .disabled(!session.isScanning)
        Button(session.isLegendVisible ? "Hide Legend" : "Show Legend") {
          session.setLegendVisible(!session.isLegendVisible)
        }
        .keyboardShortcut("l")
      }
      CommandMenu("Go") {
        Button("Back") { session.goBack() }
          .keyboardShortcut("[")
          .disabled(!session.canGoBack)
        Button("Forward") { session.goForward() }
          .keyboardShortcut("]")
          .disabled(!session.canGoForward)
        Button("Enclosing Folder") { session.zoomOut() }
          .keyboardShortcut(.upArrow)
          .disabled(!session.canZoomOut)
      }
    }
  }
}

/// Carries the window's Move to Trash request to the menu command.
struct MoveToTrashAction {
  let perform: () -> Void
  init(_ perform: @escaping () -> Void) { self.perform = perform }
}

extension FocusedValues {
  /// Asks to move the selection to the Trash. Nil when there is nothing to move.
  @Entry var moveToTrash: MoveToTrashAction?
}
