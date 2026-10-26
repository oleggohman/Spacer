import Foundation

/// When the app can update itself with Sparkle.
public enum AutoUpdate {
  /// True when the app runs from an app bundle whose Info.plist names an HTTPS feed and the
  /// public key that update archives are signed with. `swift run` builds have neither, and
  /// Sparkle would show an error at launch if it started there.
  public static func isConfigured(bundleURL: URL, info: [String: Any]) -> Bool {
    guard bundleURL.pathExtension == "app" else { return false }
    guard let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)),
      feed.scheme == "https", feed.host() != nil
    else { return false }
    guard let key = info["SUPublicEDKey"] as? String,
      Data(base64Encoded: key)?.count == 32
    else { return false }
    return true
  }

  /// `isConfigured` for the running app.
  public static func isConfigured(_ bundle: Bundle = .main) -> Bool {
    isConfigured(bundleURL: bundle.bundleURL, info: bundle.infoDictionary ?? [:])
  }
}
