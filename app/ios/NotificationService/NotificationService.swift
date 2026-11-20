import ImageIO
import Intents
import UserNotifications

/// Replaces Sygnal's placeholder ("New message") with the sender, network
/// and text, fetched from the homeserver over the tailnet. Pushes carry only
/// the room and event IDs, so no message text passes through Apple. When the
/// server can't be reached in time the placeholder stays.
///
/// A sender with a picture is drawn as a communication notification: iOS
/// puts their picture where the app's icon would be. Everything else keeps
/// the app's icon: a sender with no picture, one that can't be fetched or
/// read, and every notification while the app's setting hides senders, which
/// also says "New message" in place of the sender and the chat.
class NotificationService: UNNotificationServiceExtension {
  private var deliver: ((UNNotificationContent) -> Void)?
  private var content: UNNotificationContent?
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
    // Read once, here: the setting as it stood when the message came.
    let hideSender = NotificationPrivacy.hidesSender
    task = Task {
      let client = Client(homeserver: session.homeserver, token: session.token)
      let shown = await Self.render(
        client: client, roomId: roomId, eventId: eventId, me: session.userId, hideSender: hideSender)
      if let shown {
        content.title = shown.title
        content.subtitle = shown.subtitle
        content.body = shown.body
        // The app clears a read chat's notifications only up to the newest
        // message it has synced, so it needs the message's time.
        if let ts = shown.ts { content.userInfo["ts"] = ts }
      }
      // The text is in place, so the deadline delivers it should the
      // picture be slow.
      if let sender = shown?.sender, let picture = await client.picture(sender.pictureMxc),
        let fromSender = Self.communication(
          content, roomId: roomId, from: sender, me: session.userId, picture: picture)
      {
        self.content = fromSender
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
    /// Who to draw it as coming from. Nil when they have no picture, or
    /// senders are hidden.
    var sender: Sender? = nil
  }

  /// A sender with a picture.
  struct Sender: Equatable {
    /// Their Matrix ID.
    var id: String
    var name: String
    /// The group they wrote in, or nil in a direct chat.
    var group: String?
    var network: String?
    var pictureMxc: String
  }

  /// What stands in for the sender while senders are hidden.
  static let hiddenSender = "New message"

  static func render(
    client: Client, roomId: String, eventId: String, me: String, hideSender: Bool = false
  ) async -> Shown? {
    guard let event = await client.get("rooms/\(roomId.escaped)/event/\(eventId.escaped)"),
      let sender = event["sender"] as? String
    else { return nil }
    let ts = (event["origin_server_ts"] as? NSNumber)?.int64Value
    if hideSender {
      // Nothing about the sender or the chat is asked for, let alone shown.
      var shown = compose(event: event, senderName: "", roomName: nil, network: network(of: sender), hideSender: true)
      shown.ts = ts
      return shown
    }
    // Both at once, as separate tasks. Not `async let`: on iOS 26 the
    // optimised build aborts in the concurrency runtime when the pair
    // finishes ("asyncLet_finish_after_task_completion"), and iOS then
    // shows the push's own "New message".
    let member = Task { await client.get("rooms/\(roomId.escaped)/state/m.room.member/\(sender.escaped)") }
    let roomName = Task { await client.get("rooms/\(roomId.escaped)/state/m.room.name") }
    let roomAvatar = Task { await client.get("rooms/\(roomId.escaped)/state/m.room.avatar") }
    let memberEvent = await member.value
    let nameEvent = await roomName.value
    let avatarEvent = await roomAvatar.value
    let senderName = memberEvent?["displayname"] as? String ?? localpart(sender)
    let room = nameEvent?["name"] as? String
    let network = network(of: sender)
    var shown = compose(event: event, senderName: senderName, roomName: room, network: network)
    shown.ts = ts
    let group = isGroup(roomName: room, senderName: senderName) ? room : nil
    if let picture = pictureMxc(member: memberEvent, roomAvatar: avatarEvent, isGroup: group != nil) {
      shown.sender = Sender(id: sender, name: senderName, group: group, network: network, pictureMxc: picture)
    }
    return shown
  }

  /// Bridged DMs are named after the contact; a different name means a group.
  static func isGroup(roomName: String?, senderName: String) -> Bool {
    roomName != nil && roomName != senderName
  }

  /// The sender's picture: their own, or in a direct chat the chat's, which
  /// is the other person's. A group's picture isn't the sender's.
  static func pictureMxc(member: [String: Any]?, roomAvatar: [String: Any]?, isGroup: Bool) -> String? {
    let mxc = member?["avatar_url"] as? String ?? (isGroup ? nil : roomAvatar?["url"] as? String)
    return mxc?.hasPrefix("mxc://") == true ? mxc : nil
  }

  /// The alert for an event. Pure, so it can be tested. With `hideSender` it
  /// names nobody: neither the sender nor the chat, since a direct chat is
  /// named after the other person.
  static func compose(
    event: [String: Any], senderName: String, roomName: String?, network: String?, hideSender: Bool = false
  ) -> Shown {
    if hideSender {
      return Shown(title: hiddenSender, subtitle: network ?? "", body: text(of: event, senderName: "Someone"))
    }
    let isGroup = isGroup(roomName: roomName, senderName: senderName)
    let title = isGroup ? roomName! : senderName
    let subtitle = [isGroup ? senderName : nil, network].compactMap { $0 }.joined(separator: " · ")
    return Shown(title: title, subtitle: subtitle, body: text(of: event, senderName: senderName))
  }

  /// The notification as a message from `sender`, which is what has iOS draw
  /// their picture in place of the app's icon. Nil when iOS won't have it:
  /// the notification then stays as it is, with the app's icon.
  static func communication(
    _ content: UNNotificationContent, roomId: String, from sender: Sender, me: String, picture: Data
  ) -> UNNotificationContent? {
    let intent = message(content.body, roomId: roomId, from: sender, me: me, picture: picture)
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    interaction.donate(completion: nil)
    return try? content.updating(from: intent)
  }

  /// An incoming message as the system's intent for one.
  ///
  /// iOS words such a notification itself, from the intent and not from the
  /// title and subtitle: the sender's name, and under it the name of the
  /// group, which it shows only for a message with more than one recipient.
  /// So that line is given what the plain notification says besides the
  /// sender, the group and the network ("Family · Signal", or "WhatsApp" in
  /// a direct chat), and the recipients are the sender and `me`.
  static func message(
    _ body: String, roomId: String, from sender: Sender, me: String, picture: Data
  ) -> INSendMessageIntent {
    let image = INImage(imageData: picture)
    let person = INPerson(
      personHandle: INPersonHandle(value: sender.id, type: .unknown), nameComponents: nil,
      displayName: sender.name, image: image, contactIdentifier: nil, customIdentifier: sender.id)
    let myself = INPerson(
      personHandle: INPersonHandle(value: me, type: .unknown), nameComponents: nil,
      displayName: nil, image: nil, contactIdentifier: nil, customIdentifier: me, isMe: true)
    let place = placeLine(of: sender)
    let intent = INSendMessageIntent(
      recipients: place == nil ? nil : [person, myself], outgoingMessageType: .outgoingMessageText, content: body,
      speakableGroupName: place.map { INSpeakableString(spokenPhrase: $0) },
      conversationIdentifier: roomId, serviceName: sender.network, sender: person, attachments: nil)
    // A message with a group line is drawn with the group's picture, so
    // that is given the sender's. (The Mac, where the tests run, has no
    // such call.)
    #if os(iOS)
      if place != nil { intent.setImage(image, forParameterNamed: \.speakableGroupName) }
    #endif
    return intent
  }

  /// The line under the sender's name: where they wrote. Nil when there is
  /// neither a group nor a network to name.
  static func placeLine(of sender: Sender) -> String? {
    let place = [sender.group, sender.network].compactMap { $0 }.joined(separator: " · ")
    return place.isEmpty ? nil : place
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

  /// A picture's bytes from its mxc:// URI, cut square by the server. Nil
  /// when it can't be fetched in time or isn't an image iOS can read.
  func picture(_ mxc: String, size: Int = 192) async -> Data? {
    guard let path = Self.mediaPath(mxc),
      let url = URL(
        string: "\(homeserver)/_matrix/client/v1/media/thumbnail/\(path)?width=\(size)&height=\(size)&method=crop")
    else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 6)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      Self.isImage(data)
    else { return nil }
    return data
  }

  /// "server/media ID" from "mxc://server/media ID", for a URL path.
  static func mediaPath(_ mxc: String) -> String? {
    guard mxc.hasPrefix("mxc://") else { return nil }
    let parts = mxc.dropFirst("mxc://".count).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return "\(String(parts[0]).escaped)/\(String(parts[1]).escaped)"
  }

  static func isImage(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    return CGImageSourceGetCount(source) > 0 && CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
  }
}

extension String {
  /// Percent-encodes a Matrix ID for a URL path segment.
  var escaped: String {
    addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
  }
}
