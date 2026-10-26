import Foundation
import Testing

@testable import SpacerCore

private func volume(at url: URL, ejectable: Bool = false) -> VolumeInfo {
  VolumeInfo(
    url: url, name: url.lastPathComponent, totalCapacity: 0, availableCapacity: 0,
    isEjectable: ejectable)
}

/// Runs hdiutil with `arguments` and reports whether it succeeded. False when it cannot start.
private func hdiutil(_ arguments: [String]) -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
  process.arguments = arguments
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
  } catch {
    return false
  }
  process.waitUntilExit()
  return process.terminationStatus == 0
}

@MainActor private func isIdle(_ session: ScanSession) -> Bool {
  if case .idle = session.state { return true }
  return false
}

@MainActor @Suite struct VolumeEjectTests {
  @Test func volumeContainsItsRootAndFolders() {
    let foo = volume(at: URL(fileURLWithPath: "/Volumes/Foo", isDirectory: true))
    #expect(foo.contains(URL(fileURLWithPath: "/Volumes/Foo", isDirectory: true)))
    #expect(foo.contains(URL(fileURLWithPath: "/Volumes/Foo/a/b.bin")))
    #expect(foo.contains(URL(fileURLWithPath: "/Volumes/Foo/")))
  }

  @Test func volumeDoesNotContainSiblingWithSharedPrefix() {
    let foo = volume(at: URL(fileURLWithPath: "/Volumes/Foo", isDirectory: true))
    #expect(!foo.contains(URL(fileURLWithPath: "/Volumes/FooBar")))
    #expect(!foo.contains(URL(fileURLWithPath: "/Volumes/FooBar/a")))
    #expect(!foo.contains(URL(fileURLWithPath: "/Volumes")))
    #expect(!foo.contains(URL(fileURLWithPath: "/Volumes/Other/Foo")))
  }

  @Test func volumeContainsStandardizedPaths() {
    let foo = volume(at: URL(fileURLWithPath: "/Volumes/Foo", isDirectory: true))
    #expect(foo.contains(URL(fileURLWithPath: "/Volumes/Foo/a/../b")))
    #expect(!foo.contains(URL(fileURLWithPath: "/Volumes/Foo/../FooBar")))
  }

  @Test func rootVolumeContainsEveryPath() {
    let root = volume(at: URL(fileURLWithPath: "/", isDirectory: true))
    #expect(root.contains(URL(fileURLWithPath: "/")))
    #expect(root.contains(URL(fileURLWithPath: "/Volumes/Foo")))
  }

  @Test func volumeIsNotEjectableByDefault() {
    let disk = VolumeInfo(
      url: URL(fileURLWithPath: "/Volumes/Foo"), name: "Foo", totalCapacity: 1,
      availableCapacity: 1)
    #expect(!disk.isEjectable)
  }

  @Test func startupDiskIsNotEjectable() throws {
    let startup = try #require(VolumeInfo.mounted().first { $0.url.path == "/" })
    #expect(!startup.isEjectable)
  }

  @Test func ejectRefusesVolumeThatIsNotEjectable() async {
    let disk = volume(at: URL(fileURLWithPath: "/Volumes/Fixed", isDirectory: true))
    await #expect(throws: VolumeEjector.EjectError.notEjectable(name: "Fixed")) {
      try await VolumeEjector.eject(disk)
    }
  }

  @Test func ejectNeverUnmountsTheStartupDisk() async {
    let startup = volume(at: URL(fileURLWithPath: "/", isDirectory: true), ejectable: true)
    await #expect(throws: VolumeEjector.EjectError.notEjectable(name: "/")) {
      try await VolumeEjector.eject(startup)
    }
  }

  @Test func releaseScanClearsTheScanUnderTheVolume() async throws {
    let tree = try TempTree()
    try tree.file("a.bin", bytes: 4096)
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()
    #expect(session.root != nil)

    await session.releaseScan(on: volume(at: tree.root, ejectable: true))

    #expect(session.scanURL == nil)
    #expect(session.root == nil)
    #expect(session.focus == nil)
    #expect(session.retainedScan == nil)
    #expect(isIdle(session))
  }

  @Test func releaseScanStopsARunningScanUnderTheVolume() async throws {
    let tree = try TempTree()
    try tree.file("a.bin", bytes: 4096)
    let session = ScanSession()
    session.start(url: tree.root)
    #expect(session.isScanning)

    await session.releaseScan(on: volume(at: tree.root, ejectable: true))

    #expect(session.scanURL == nil)
    #expect(!session.isScanning)
    #expect(isIdle(session))
  }

  @Test func releaseScanLeavesAScanElsewhereAlone() async throws {
    let tree = try TempTree()
    try tree.file("a.bin", bytes: 4096)
    let other = try TempTree()
    let session = ScanSession()
    session.start(url: tree.root)
    await session.waitForScan()

    await session.releaseScan(on: volume(at: other.root, ejectable: true))

    #expect(session.scanURL == tree.root)
    #expect(session.root != nil)
    #expect(session.finishedAt != nil)
  }

  /// Mounts a small APFS disk image, ejects it and checks it is gone from the mounted volumes.
  /// Quietly returns when hdiutil cannot create or attach an image here.
  @Test func ejectUnmountsADiskImage() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpacerEject-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let image = dir.appendingPathComponent("eject-test.dmg")
    let mountPoint = dir.appendingPathComponent("mount", isDirectory: true)
    try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
    defer {
      // Only does something when the image is still mounted. Errors are ignored.
      _ = hdiutil(["detach", "-force", mountPoint.path])
      try? FileManager.default.removeItem(at: dir)
    }
    guard
      hdiutil([
        "create", "-size", "2m", "-fs", "APFS", "-volname", "SpacerEjectTest", image.path,
      ]),
      // Not -nobrowse: such volumes are hidden and would not be listed by `mounted()`.
      hdiutil(["attach", "-noautoopen", "-mountpoint", mountPoint.path, image.path])
    else { return }

    let mounted = try #require(
      VolumeInfo.mounted().first {
        $0.url.resolvingSymlinksInPath() == mountPoint.resolvingSymlinksInPath()
      })
    #expect(mounted.isEjectable)

    try await VolumeEjector.eject(mounted)

    #expect(!VolumeInfo.mounted().contains { $0.id == mounted.id })
  }
}
