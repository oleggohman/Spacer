import Foundation
import SpacerCore
import Sparkle

/// Sparkle's updater, which checks the appcast in the background and backs the
/// Check for Updates menu command. Inactive when the app is not a configured bundle.
@MainActor @Observable final class AppUpdater {
  /// True when Sparkle runs, so the menu command is shown.
  let isAvailable: Bool
  /// False while a check or an update is already in progress.
  private(set) var canCheckForUpdates = false

  @ObservationIgnored private let controller: SPUStandardUpdaterController?
  @ObservationIgnored private var observation: NSKeyValueObservation?

  init() {
    guard AutoUpdate.isConfigured() else {
      controller = nil
      isAvailable = false
      return
    }
    let controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    self.controller = controller
    isAvailable = true
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
      [weak self] _, change in
      let canCheck = change.newValue ?? false
      Task { @MainActor in self?.canCheckForUpdates = canCheck }
    }
  }

  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }
}
