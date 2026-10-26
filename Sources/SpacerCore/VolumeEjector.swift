import Foundation

/// Unmounts a volume from the sidebar and ejects its disk when it can.
public enum VolumeEjector {
  /// Why a volume cannot be ejected.
  public enum EjectError: LocalizedError, Equatable {
    /// The volume is not one the sidebar offers to eject, such as the startup disk.
    case notEjectable(name: String)

    public var errorDescription: String? {
      switch self {
      case .notEjectable(let name):
        "“\(name)” can’t be ejected."
      }
    }
  }

  /// Unmounts `volume` and ejects its disk, with the system's partitions and eject options and
  /// no dialogs. Throws `EjectError.notEjectable` for any volume `isEjectable` does not mark, so
  /// the startup disk is never unmounted. Throws the system's error when the volume is busy.
  public static func eject(_ volume: VolumeInfo) async throws {
    guard volume.isEjectable, volume.url.path != "/" else {
      throw EjectError.notEjectable(name: volume.name)
    }
    try await FileManager.default.unmountVolume(
      at: volume.url, options: [.allPartitionsAndEjectDisk, .withoutUI])
  }
}
