import Foundation
import Testing

@testable import SpacerCore

@Suite struct AutoUpdateTests {
  let app = URL(fileURLWithPath: "/Applications/Spacer.app")
  let info: [String: Any] = [
    "SUFeedURL": "https://example.com/appcast.xml",
    "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
  ]

  @Test func appBundleWithFeedAndKeyIsConfigured() {
    #expect(AutoUpdate.isConfigured(bundleURL: app, info: info))
  }

  @Test func plainExecutableIsNotConfigured() {
    let debug = URL(fileURLWithPath: "/tmp/.build/debug")
    #expect(!AutoUpdate.isConfigured(bundleURL: debug, info: info))
  }

  @Test(arguments: [nil, "", "not a url", "http://example.com/appcast.xml", "https:///appcast.xml"])
  func missingOrInsecureFeedIsNotConfigured(feed: String?) {
    var info = info
    info["SUFeedURL"] = feed
    #expect(!AutoUpdate.isConfigured(bundleURL: app, info: info))
  }

  @Test(arguments: [nil, "", "not base64!", Data(count: 16).base64EncodedString()])
  func missingOrMalformedKeyIsNotConfigured(key: String?) {
    var info = info
    info["SUPublicEDKey"] = key
    #expect(!AutoUpdate.isConfigured(bundleURL: app, info: info))
  }

  @Test func shippedInfoPlistIsConfigured() throws {
    let plist = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Info.plist")
    let data = try Data(contentsOf: plist)
    let info = try #require(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(AutoUpdate.isConfigured(bundleURL: app, info: info))
  }
}
