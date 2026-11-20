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

  /// The shared group's item for `account`.
  fileprivate static func query(_ account: String) -> [CFString: Any] {
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
    SecItemDelete(query(account) as CFDictionary)
    guard let json, let data = json.data(using: .utf8) else { return }
    var add = query(account)
    add[kSecValueData] = data
    // The extension runs while the phone is locked.
    add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(add as CFDictionary, nil)
  }

  static func load() -> (homeserver: String, token: String, userId: String)? {
    var q = query(account)
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

/// Whether notifications hide who sent a message: the app's setting, where
/// the extension can read it. An item in the shared keychain group that
/// exists while senders are hidden.
enum NotificationPrivacy {
  private static let account = "hide_sender"

  /// False only when the keychain says there is no such item. While it
  /// can't be read (before the first unlock, say) senders stay hidden.
  static var hidesSender: Bool {
    var q = SharedSession.query(account)
    q[kSecMatchLimit] = kSecMatchLimitOne
    return SecItemCopyMatching(q as CFDictionary, nil) != errSecItemNotFound
  }

  /// The keychain calls the setting is stored with. A test stands in for
  /// them to see which are made.
  struct Keychain {
    var add: ([CFString: Any]) -> OSStatus = { SecItemAdd($0 as CFDictionary, nil) }
    var delete: ([CFString: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }
  }

  /// Returns whether the keychain took the change.
  ///
  /// Hiding only ever adds the item, and one already there is left alone:
  /// the app stores the setting at every launch, and were that to remove
  /// the item first, a message arriving in between would find none and name
  /// its sender. Only showing senders removes it.
  @discardableResult
  static func store(_ hide: Bool, in keychain: Keychain = Keychain()) -> Bool {
    guard hide else {
      let removed = keychain.delete(SharedSession.query(account))
      return removed == errSecSuccess || removed == errSecItemNotFound
    }
    var add = SharedSession.query(account)
    add[kSecValueData] = Data([1])
    // The extension runs while the phone is locked.
    add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = keychain.add(add)
    return added == errSecSuccess || added == errSecDuplicateItem
  }
}
