// Checks the notification extension's wording on macOS, and optionally
// renders a real event from the server:
//   tool/test-notification-service.sh
//   SB_SERVER=https://switchboard.<tailnet>.ts.net SB_TOKEN=... SB_ROOM=... SB_EVENT=... \
//     tool/test-notification-service.sh
// With SB_HIDE_SENDER=1 too, it renders the event as the setting to hide
// senders would.
import Foundation

var failures = 0
func expect(_ got: String, _ want: String, _ what: String) {
  if got != want {
    failures += 1
    print("FAIL \(what): got \"\(got)\", want \"\(want)\"")
  }
}

let text: [String: Any] = ["type": "m.room.message", "content": ["msgtype": "m.text", "body": "See you at 7"]]
let dm = NotificationService.compose(event: text, senderName: "Alice", roomName: "Alice", network: "WhatsApp")
expect(dm.title, "Alice", "DM title")
expect(dm.subtitle, "WhatsApp", "DM subtitle")
expect(dm.body, "See you at 7", "DM body")

let group = NotificationService.compose(event: text, senderName: "Mum", roomName: "Family", network: "Signal")
expect(group.title, "Family", "group title")
expect(group.subtitle, "Mum · Signal", "group subtitle")

let plain = NotificationService.compose(event: text, senderName: "Bob", roomName: nil, network: nil)
expect(plain.title, "Bob", "unnamed room title")
expect(plain.subtitle, "", "no network")

func body(_ content: [String: Any], type: String = "m.room.message") -> String {
  NotificationService.text(of: ["type": type, "content": content], senderName: "Alice")
}
expect(body(["msgtype": "m.image", "body": "IMG_1.jpg"]), "📷 Photo", "photo")
expect(body(["msgtype": "m.audio", "body": "a.m4a", "org.matrix.msc3245.voice": [:]]), "🎤 Voice message", "voice")
expect(body(["msgtype": "m.audio", "body": "a.mp3"]), "🎵 Audio", "audio")
expect(body(["msgtype": "m.file", "body": "x", "filename": "notes.pdf"]), "📎 notes.pdf", "file")
expect(body(["msgtype": "m.emote", "body": "waves"]), "* Alice waves", "emote")
expect(body(["m.relates_to": ["key": "👍"]], type: "m.reaction"), "Reacted 👍", "reaction")
expect(body([:], type: "m.room.encrypted"), "Encrypted message", "encrypted")

expect(NotificationService.network(of: "@whatsapp_447700900123:switchboard.internal") ?? "-", "WhatsApp", "WhatsApp puppet")
expect(NotificationService.network(of: "@signal_1b2c:switchboard.internal") ?? "-", "Signal", "Signal puppet")
expect(NotificationService.network(of: "@alice:switchboard.internal") ?? "-", "-", "plain user")
expect(NotificationService.localpart("@richard:switchboard.internal"), "richard", "localpart")

// Hiding senders: no sender, chat or picture, in a direct chat or a group.
func check(_ got: Bool, _ what: String) {
  if !got {
    failures += 1
    print("FAIL \(what)")
  }
}
let emote: [String: Any] = ["type": "m.room.message", "content": ["msgtype": "m.emote", "body": "waves"]]
for (name, room) in [("Alice", "Alice"), ("Mum", "Family")] {
  for event in [text, emote] {
    let hidden = NotificationService.compose(
      event: event, senderName: name, roomName: room, network: "WhatsApp", hideSender: true)
    expect(hidden.title, "New message", "hidden title")
    expect(hidden.subtitle, "WhatsApp", "hidden subtitle")
    let shown = [hidden.title, hidden.subtitle, hidden.body].joined(separator: "\n")
    check(!shown.contains(name) && !shown.contains(room), "hidden notification names \(name) or \(room): \(shown)")
    check(hidden.sender == nil, "hidden notification has a sender to draw")
  }
}
expect(
  NotificationService.compose(event: text, senderName: "Alice", roomName: "Alice", network: nil, hideSender: true).body,
  "See you at 7", "hidden body keeps the text")
expect(
  NotificationService.compose(event: emote, senderName: "Alice", roomName: "Alice", network: nil, hideSender: true).body,
  "* Someone waves", "hidden emote")

// The sender's picture: their own, or a direct chat's; never a group's.
let ownPicture: [String: Any] = ["displayname": "Alice", "avatar_url": "mxc://example.org/alice"]
let roomPicture: [String: Any] = ["url": "mxc://example.org/room"]
func picture(_ member: [String: Any]?, _ room: [String: Any]?, group: Bool) -> String {
  NotificationService.pictureMxc(member: member, roomAvatar: room, isGroup: group) ?? "-"
}
expect(picture(ownPicture, roomPicture, group: false), "mxc://example.org/alice", "own picture in a DM")
expect(picture(ownPicture, roomPicture, group: true), "mxc://example.org/alice", "own picture in a group")
expect(picture(["displayname": "Alice"], roomPicture, group: false), "mxc://example.org/room", "DM's picture")
expect(picture(["displayname": "Alice"], roomPicture, group: true), "-", "a group's picture isn't the sender's")
expect(picture(nil, nil, group: false), "-", "no picture")
expect(picture(["avatar_url": "https://example.org/a.png"], nil, group: false), "-", "not an mxc URI")
expect(picture(["avatar_url": ""], nil, group: false), "-", "empty picture")

expect(Client.mediaPath("mxc://example.org/abc123") ?? "-", "example.org/abc123", "media path")
expect(Client.mediaPath("mxc://localhost:8448/a b") ?? "-", "localhost%3A8448/a%20b", "media path escapes")
expect(Client.mediaPath("mxc://example.org") ?? "-", "-", "media path without an ID")
expect(Client.mediaPath("mxc://example.org/a/b") ?? "-", "-", "media path with extra parts")
expect(Client.mediaPath("https://example.org/a") ?? "-", "-", "media path of another scheme")

// A 1 x 1 PNG.
let png = Data(
  base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
check(Client.isImage(png), "a PNG is an image")
check(!Client.isImage(Data("<html>not found</html>".utf8)), "an error page isn't an image")
check(!Client.isImage(Data()), "nothing isn't an image")

// The message iOS draws the picture from.
let alice = NotificationService.Sender(
  id: "@whatsapp_447700900123:switchboard.internal", name: "Alice", group: nil, network: "WhatsApp",
  pictureMxc: "mxc://example.org/alice")
let fromAlice = NotificationService.message("See you at 7", roomId: "!dm:switchboard.internal", from: alice, picture: png)
expect(fromAlice.sender?.displayName ?? "-", "Alice", "message's sender")
check(fromAlice.sender?.image != nil, "message's sender has their picture")
expect(fromAlice.conversationIdentifier ?? "-", "!dm:switchboard.internal", "message's chat")
expect(fromAlice.content ?? "-", "See you at 7", "message's text")
check(fromAlice.speakableGroupName == nil, "a DM has no group")
var mum = alice
mum.name = "Mum"
mum.group = "Family"
let fromMum = NotificationService.message("Photo", roomId: "!family:switchboard.internal", from: mum, picture: png)
expect(fromMum.speakableGroupName?.spokenPhrase ?? "-", "Family", "message's group")
check(fromMum.sender?.image != nil, "a group message's sender has their picture")

let env = ProcessInfo.processInfo.environment
if let token = env["SB_TOKEN"], let room = env["SB_ROOM"], let event = env["SB_EVENT"] {
  let client = Client(homeserver: env["SB_SERVER"] ?? "https://switchboard.example.ts.net", token: token)
  let done = DispatchSemaphore(value: 0)
  Task {
    // SB_HIDE_SENDER=1 renders it as the setting to hide senders would.
    let hide = env["SB_HIDE_SENDER"] == "1"
    if let shown = await NotificationService.render(client: client, roomId: room, eventId: event, me: "", hideSender: hide) {
      print("live: title=\"\(shown.title)\" subtitle=\"\(shown.subtitle)\" body=\"\(shown.body)\" ts=\(shown.ts.map(String.init) ?? "-")")
      if let sender = shown.sender {
        let bytes = await client.picture(sender.pictureMxc)?.count
        print("live: picture=\(sender.pictureMxc) \(bytes.map { "\($0) bytes" } ?? "not fetched")")
      } else {
        print("live: no picture, so the app's icon")
      }
      if shown.ts == nil {
        failures += 1
        print("FAIL live render has no message time")
      }
    } else {
      failures += 1
      print("FAIL live render returned nothing")
    }
    done.signal()
  }
  done.wait()
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
