import Foundation
import Testing

/// Keeps Resources/Profiles/Spacer-PPPC.mobileconfig.template in step with the app:
/// scripts/make-pppc-profile.sh fills it, and an MDM matches its entries against the app.
@Suite struct PPPCProfileTemplateTests {
  static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  static func plist(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: root.appendingPathComponent(path))
    let object = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(object as? [String: Any])
  }

  static func template() throws -> [String: Any] {
    try plist("Resources/Profiles/Spacer-PPPC.mobileconfig.template")
  }

  static func tccPayload() throws -> [String: Any] {
    let content = try #require(try template()["PayloadContent"] as? [[String: Any]])
    #expect(content.count == 1)
    return try #require(content.first)
  }

  @Test func profileMetadataIsFixed() throws {
    let profile = try Self.template()
    #expect(profile["PayloadIdentifier"] as? String == "com.oleggohman.spacer.pppc")
    #expect(profile["PayloadUUID"] as? String == "EDEBDDA3-137D-4EA3-8D90-F702820611D3")
    #expect(profile["PayloadScope"] as? String == "System")
    #expect(profile["PayloadType"] as? String == "Configuration")

    let payload = try Self.tccPayload()
    #expect(payload["PayloadType"] as? String == "com.apple.TCC.configuration-profile-policy")
    #expect(payload["PayloadUUID"] as? String == "023607AD-1F7F-4C04-AB20-91C04DD38F30")
  }

  @Test func grantsExactlyTheSixServices() throws {
    let services = try #require(try Self.tccPayload()["Services"] as? [String: Any])
    #expect(
      Set(services.keys) == [
        "SystemPolicyAllFiles", "SystemPolicyRemovableVolumes", "SystemPolicyNetworkVolumes",
        "SystemPolicyDesktopFolder", "SystemPolicyDocumentsFolder", "SystemPolicyDownloadsFolder",
      ])
  }

  @Test func everyEntryMatchesTheAppBundleID() throws {
    let info = try Self.plist("Resources/Info.plist")
    let appID = try #require(info["CFBundleIdentifier"] as? String)
    let services = try #require(try Self.tccPayload()["Services"] as? [String: [[String: Any]]])
    for (service, entries) in services {
      #expect(entries.count == 1, "\(service)")
      let entry = try #require(entries.first)
      #expect(entry["Identifier"] as? String == appID, "\(service)")
      #expect(entry["IdentifierType"] as? String == "bundleID", "\(service)")
      #expect(entry["CodeRequirement"] as? String == "__CODE_REQUIREMENT__", "\(service)")
      #expect(entry["Allowed"] as? Bool == true, "\(service)")
      #expect(entry["StaticCode"] as? Bool == false, "\(service)")
    }
  }
}
