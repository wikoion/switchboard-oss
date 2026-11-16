import Foundation
import Security

/// The session the notification extension uses to fetch messages: the
/// homeserver URL and access token, in a keychain group the app and the
/// extension share. Compiled into both targets.
enum SharedSession {
  private static let service = "switchboard.extension"
  private static let account = "session"

  /// "<team prefix>com.richarddraycott.switchboard.shared", from the
  /// AppIdentifierPrefix each target's Info.plist carries.
  static var accessGroup: String? {
    guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
      !prefix.isEmpty
    else { return nil }
    return prefix + "com.richarddraycott.switchboard.shared"
  }

  private static func query() -> [CFString: Any] {
    var q: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    if let group = accessGroup { q[kSecAttrAccessGroup] = group }
    return q
  }

  /// Stores the session JSON, or removes it when nil.
  static func store(_ json: String?) {
    SecItemDelete(query() as CFDictionary)
    guard let json, let data = json.data(using: .utf8) else { return }
    var add = query()
    add[kSecValueData] = data
    // The extension runs while the phone is locked.
    add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(add as CFDictionary, nil)
  }

  static func load() -> (homeserver: String, token: String, userId: String)? {
    var q = query()
    q[kSecReturnData] = true
    q[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let homeserver = json["homeserver_url"] as? String,
      let session = json["session"] as? [String: Any],
      let token = session["access_token"] as? String,
      let userId = session["user_id"] as? String
    else { return nil }
    return (homeserver, token, userId)
  }
}
