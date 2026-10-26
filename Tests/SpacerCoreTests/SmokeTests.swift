import Testing

@testable import SpacerCore

@Test func coreModuleLoads() {
  #expect(AppInfo.appName == "Spacer")
  #expect(AppInfo.bundleIdentifier == "com.oleggohman.spacer")
}
