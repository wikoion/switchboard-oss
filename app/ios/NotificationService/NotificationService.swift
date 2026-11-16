import UserNotifications

/// Replaces Sygnal's placeholder ("New message") with the sender, network
/// and text, fetched from the homeserver over the tailnet. Pushes carry only
/// the room and event IDs, so no message text passes through Apple. When the
/// server can't be reached in time the placeholder stays.
class NotificationService: UNNotificationServiceExtension {
  private var deliver: ((UNNotificationContent) -> Void)?
  private var content: UNMutableNotificationContent?
  private var task: Task<Void, Never>?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
    self.content = content
    self.deliver = contentHandler
    let info = request.content.userInfo
    guard let roomId = info["room_id"] as? String,
      let eventId = info["event_id"] as? String,
      let session = SharedSession.load()
    else {
      finish()
      return
    }
    content.threadIdentifier = roomId
    task = Task {
      let client = Client(homeserver: session.homeserver, token: session.token)
      if let shown = await Self.render(client: client, roomId: roomId, eventId: eventId, me: session.userId) {
        content.title = shown.title
        content.subtitle = shown.subtitle
        content.body = shown.body
        // The app clears a read chat's notifications only up to the newest
        // message it has synced, so it needs the message's time.
        if let ts = shown.ts { content.userInfo["ts"] = ts }
      }
      self.finish()
    }
  }

  override func serviceExtensionTimeWillExpire() {
    task?.cancel()
    finish()
  }

  /// Delivers once, whichever of the fetch and the deadline comes first.
  private func finish() {
    guard let deliver, let content else { return }
    self.deliver = nil
    deliver(content)
  }

  struct Shown: Equatable {
    var title: String
    var subtitle: String
    var body: String
    /// The message's `origin_server_ts`, in ms.
    var ts: Int64? = nil
  }

  static func render(client: Client, roomId: String, eventId: String, me: String) async -> Shown? {
    guard let event = await client.get("rooms/\(roomId.escaped)/event/\(eventId.escaped)"),
      let sender = event["sender"] as? String
    else { return nil }
    // Both at once, as separate tasks. Not `async let`: on iOS 26 the
    // optimised build aborts in the concurrency runtime when the pair
    // finishes ("asyncLet_finish_after_task_completion"), and iOS then
    // shows the push's own "New message".
    let member = Task { await client.get("rooms/\(roomId.escaped)/state/m.room.member/\(sender.escaped)") }
    let roomName = Task { await client.get("rooms/\(roomId.escaped)/state/m.room.name") }
    let memberEvent = await member.value
    let nameEvent = await roomName.value
    let senderName = memberEvent?["displayname"] as? String ?? localpart(sender)
    let room = nameEvent?["name"] as? String
    var shown = compose(event: event, senderName: senderName, roomName: room, network: network(of: sender))
    shown.ts = (event["origin_server_ts"] as? NSNumber)?.int64Value
    return shown
  }

  /// The alert for an event. Pure, so it can be tested.
  static func compose(event: [String: Any], senderName: String, roomName: String?, network: String?) -> Shown {
    // Bridged DMs are named after the contact; a different name means a group.
    let isGroup = roomName != nil && roomName != senderName
    let title = isGroup ? roomName! : senderName
    let subtitle = [isGroup ? senderName : nil, network].compactMap { $0 }.joined(separator: " · ")
    return Shown(title: title, subtitle: subtitle, body: text(of: event, senderName: senderName))
  }

  static func text(of event: [String: Any], senderName: String) -> String {
    let content = event["content"] as? [String: Any] ?? [:]
    switch event["type"] as? String {
    case "m.room.encrypted":
      return "Encrypted message"
    case "m.sticker":
      return "Sticker"
    case "m.reaction":
      let key = (content["m.relates_to"] as? [String: Any])?["key"] as? String ?? ""
      return "Reacted \(key)"
    default:
      break
    }
    let body = content["body"] as? String ?? ""
    switch content["msgtype"] as? String {
    case "m.image": return "📷 Photo"
    case "m.video": return "🎥 Video"
    case "m.audio": return content["org.matrix.msc3245.voice"] != nil ? "🎤 Voice message" : "🎵 Audio"
    case "m.file": return "📎 \(content["filename"] as? String ?? body)"
    case "m.location": return "📍 Location"
    case "m.emote": return "* \(senderName) \(body)"
    default: return body.isEmpty ? "New message" : body
    }
  }

  /// mautrix names its puppets after the network: @whatsapp_447…, @signal_….
  static func network(of userId: String) -> String? {
    let prefix = localpart(userId).split(separator: "_").first.map(String.init) ?? ""
    return [
      "whatsapp": "WhatsApp", "signal": "Signal", "telegram": "Telegram", "meta": "Messenger",
      "facebook": "Messenger", "instagram": "Instagram", "twitter": "X", "linkedin": "LinkedIn",
      "discord": "Discord", "slack": "Slack", "gmessages": "Google Messages", "googlechat": "Google Chat",
      "imessage": "iMessage",
    ][prefix]
  }

  static func localpart(_ userId: String) -> String {
    String(userId.dropFirst().prefix { $0 != ":" })
  }
}

/// A minimal Matrix client: authenticated GETs that give up quickly.
struct Client {
  let homeserver: String
  let token: String

  func get(_ path: String) async -> [String: Any]? {
    guard let url = URL(string: "\(homeserver)/_matrix/client/v3/\(path)") else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}

extension String {
  /// Percent-encodes a Matrix ID for a URL path segment.
  var escaped: String {
    addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
  }
}
