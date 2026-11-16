// Checks the notification extension's wording on macOS, and optionally
// renders a real event from the server:
//   tool/test-notification-service.sh
//   SB_SERVER=https://switchboard.<tailnet>.ts.net SB_TOKEN=... SB_ROOM=... SB_EVENT=... \
//     tool/test-notification-service.sh
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

let env = ProcessInfo.processInfo.environment
if let token = env["SB_TOKEN"], let room = env["SB_ROOM"], let event = env["SB_EVENT"] {
  let client = Client(homeserver: env["SB_SERVER"] ?? "https://switchboard.example.ts.net", token: token)
  let done = DispatchSemaphore(value: 0)
  Task {
    if let shown = await NotificationService.render(client: client, roomId: room, eventId: event, me: "") {
      print("live: title=\"\(shown.title)\" subtitle=\"\(shown.subtitle)\" body=\"\(shown.body)\" ts=\(shown.ts.map(String.init) ?? "-")")
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
