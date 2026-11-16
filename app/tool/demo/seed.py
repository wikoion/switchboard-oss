#!/usr/bin/env python3
"""Fills the demo homeserver with fictional chats, as bridges would.

    seed.py chats HOMESERVER_URL DOMAIN OWNER AS_TOKEN PENDING_FILE
    seed.py unread HOMESERVER_URL DOMAIN OWNER AS_TOKEN PENDING_FILE

Every person, number and message here is made up. Contacts are registered
as the appservice's ghost users and chats carry `m.bridge` state naming a
network, so the app badges them as WhatsApp, Signal and so on; no bridge or
network is involved. Messages are backdated with the appservice `ts`
parameter so the inbox reads like a morning's activity, ending at 09:40
today (the screenshots' status bar says 9:41).

`chats` makes the chats but holds back each one's unread messages, saving
them in PENDING_FILE; `unread` sends them. The app counts unread messages
from the events it has, and a first sync brings only each chat's newest, so
send the unread ones while the app is running and synced.
"""

import io
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta

MODE, HS, DOMAIN, OWNER, AS_TOKEN, PENDING = sys.argv[1:7]
ME = f"@{OWNER}:{DOMAIN}"

NETWORKS = {
    "whatsapp": "WhatsApp",
    "signal": "Signal",
    "telegram": "Telegram",
    "slackgo": "Slack",
    "discordgo": "Discord",
    "instagramgo": "Instagram",
    "matrix": "Matrix",
}

# Ghost users: key -> (localpart, display name).
PEOPLE = {
    "priya": ("whatsapp_447700900211", "Priya Shah"),
    "mum": ("whatsapp_447700900302", "Mum"),
    "dad": ("whatsapp_447700900303", "Dad"),
    "sophie": ("whatsapp_447700900318", "Sophie"),
    "kofi": ("whatsapp_447700900527", "Kofi Mensah"),
    "tom": ("signal_3f6b1c2d", "Tom Becker"),
    "grace": ("signal_9a4e7f10", "Grace Okafor"),
    "sam": ("signal_c2d81e55", "Sam Okoro"),
    "ruth": ("signal_7b19aa03", "Ruth Ellis"),
    "jonas": ("telegram_52817734", "Jonas Weber"),
    "maya": ("slackgo_t0nwind-u07maya", "Maya Lindqvist"),
    "ben": ("slackgo_t0nwind-u03ben", "Ben Carter"),
    "ines": ("discordgo_412233445566", "Ines"),
    "marco": ("discordgo_412233445577", "Marco"),
    "dev": ("discordgo_412233445588", "Dev"),
    "lena": ("instagramgo_17841400211", "Lena Novak"),
    "iris": ("matrix_iris", "Iris Chen"),
    "oskar": ("matrix_oskar", "Oskar Berg"),
}


def anchor():
    """The newest message's time: 09:40 today, or a minute ago if earlier."""
    now = datetime.now()
    nine40 = now.replace(hour=9, minute=40, second=0, microsecond=0)
    return min(nine40, now - timedelta(minutes=1))


A = anchor()


def ts(day, hhmm):
    """Milliseconds for HH:MM `day` days before today, never after A."""
    h, m = map(int, hhmm.split(":"))
    t = (A - timedelta(days=day)).replace(hour=h, minute=m, second=0, microsecond=0)
    return int(min(t, A).timestamp() * 1000)


def call(method, path, body=None, as_user=None, query=None, raw=None, content_type=None):
    q = dict(query or {})
    if as_user:
        q["user_id"] = as_user
    url = HS + path + ("?" + urllib.parse.urlencode(q) if q else "")
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {AS_TOKEN}")
    req.add_header("Content-Type", content_type or "application/json")
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req) as resp:
                text = resp.read().decode()
                return json.loads(text) if text else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode()
            if e.code == 429 and attempt < 4:
                time.sleep(1)
                continue
            raise SystemExit(f"{method} {path}: HTTP {e.code}: {detail}")


def mxid(key):
    return ME if key == "me" else f"@{PEOPLE[key][0]}:{DOMAIN}"


def register_people():
    for key, (local, name) in PEOPLE.items():
        try:
            call("POST", "/_matrix/client/v3/register",
                 {"type": "m.login.application_service", "username": local})
        except SystemExit as e:
            if "M_USER_IN_USE" not in str(e):
                raise
        call("PUT", f"/_matrix/client/v3/profile/{urllib.parse.quote(mxid(key))}/displayname",
             {"displayname": name}, as_user=mxid(key))
    call("PUT", f"/_matrix/client/v3/profile/{urllib.parse.quote(ME)}/displayname",
         {"displayname": "Alex Rivera"}, as_user=ME)


def emoji_avatar(emoji, colour):
    """A group photo: an emoji on a soft colour. None without Pillow."""
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        return None
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Apple Color Emoji.ttc", 160)
    except OSError:
        return None
    glyph = Image.new("RGBA", (320, 320), (0, 0, 0, 0))
    ImageDraw.Draw(glyph).text((20, 20), emoji, font=font, embedded_color=True)
    glyph = glyph.crop(glyph.getbbox())
    size = 512
    glyph.thumbnail((int(size * 0.56), int(size * 0.56)), Image.LANCZOS)
    img = Image.new("RGB", (size, size), colour)
    img.paste(glyph, ((size - glyph.width) // 2, (size - glyph.height) // 2), glyph)
    out = io.BytesIO()
    img.save(out, "PNG")
    return out.getvalue()


def upload(png, name):
    r = call("POST", "/_matrix/media/v3/upload", raw=png, content_type="image/png",
             as_user=ME, query={"filename": name})
    return r["content_uri"]


def create_chat(chat):
    network = chat["network"]
    members = [mxid(k) for k in chat["members"]]
    initial_state = [{
        "type": "m.bridge",
        "state_key": f"demo/{network}/{chat['key']}",
        "content": {
            "bridgebot": f"@{network}bot:{DOMAIN}",
            "protocol": {"id": network, "displayname": NETWORKS[network]},
            "channel": {"id": chat["key"], "displayname": chat["name"]},
        },
    }]
    if chat.get("avatar"):
        png = emoji_avatar(*chat["avatar"])
        if png:
            initial_state.append({"type": "m.room.avatar", "state_key": "",
                                  "content": {"url": upload(png, f"{chat['key']}.png")}})
    body = {
        "preset": "trusted_private_chat" if chat.get("dm") else "private_chat",
        "is_direct": bool(chat.get("dm")),
        "invite": members,
        "initial_state": initial_state,
    }
    # A DM takes its name and picture from the other person, as the room's
    # heroes; Synapse's sliding sync leaves heroes out of named rooms.
    if not chat.get("dm"):
        body["name"] = chat["name"]
    room = call("POST", "/_matrix/client/v3/createRoom", body, as_user=ME)["room_id"]
    for m in members:
        call("POST", f"/_matrix/client/v3/join/{urllib.parse.quote(room)}", {}, as_user=m)
    return room


def send(room, sender, when, content, kind="m.room.message"):
    txn = uuid.uuid4().hex
    r = call("PUT", f"/_matrix/client/v3/rooms/{urllib.parse.quote(room)}/send/{kind}/{txn}",
             content, as_user=mxid(sender), query={"ts": str(when)})
    return r["event_id"]


def receipt(room, user, event):
    call("POST", f"/_matrix/client/v3/rooms/{urllib.parse.quote(room)}/receipt/m.read/{urllib.parse.quote(event)}",
         {}, as_user=mxid(user))


# Each message: (sender, days ago, "HH:MM", text, options). Options: "reply"
# (index of the message replied to), "react" ((reactor, emoji)), "mention"
# (a person key mentioned at the start). A chat's "read" is how many of its
# last messages you haven't read; "seen" makes the contact read the last.
CHATS = [
    {"key": "priya", "name": "Priya Shah", "network": "whatsapp", "dm": True, "members": ["priya"],
     "favourite": 0.1, "seen": True, "messages": [
        ("priya", 1, "18:02", "Are we still on for Saturday?"),
        ("me", 1, "18:05", "Definitely! 7:30 at Olive & Fig?"),
        ("priya", 1, "18:06", "Perfect, I'll book a table for four"),
        ("me", 1, "18:07", "Great, I'll let Sam know"),
        ("priya", 0, "09:02", "Sam and Jess are both in 🎉", {"react": ("me", "❤️")}),
        ("priya", 0, "09:03", "Could we make it 8 though? My train gets in at 7:15", {"reply": 1}),
        ("me", 0, "09:10", "8 works for me", {"react": ("priya", "👍")}),
        ("me", 0, "09:11", "I'll bring the card for Jess. Can you grab candles?"),
        ("priya", 0, "09:20", "On it 🕯️"),
        ("priya", 0, "09:21", "Table's booked for 8, under Shah"),
        ("me", 0, "09:23", "Perfect, see you Saturday!"),
    ]},
    {"key": "family", "name": "Family", "network": "whatsapp", "members": ["mum", "dad", "sophie"],
     "favourite": 0.2, "avatar": ("🏡", (255, 236, 210)), "unread": 3, "messages": [
        ("sophie", 1, "20:14", "Who's around on Sunday?"),
        ("me", 1, "20:30", "Me! Back from Bristol on Saturday night"),
        ("dad", 0, "09:05", "Sophie, can you bring the big dish back?"),
        ("sophie", 0, "09:12", "Yes, it's in the car 🙈"),
        ("mum", 0, "09:31", "Sunday lunch at 1? Dad's doing a roast"),
    ]},
    {"key": "climbing", "name": "Climbing crew", "network": "signal", "members": ["sam", "ruth", "tom"],
     "favourite": 0.3, "avatar": ("🧗", (214, 232, 255)), "unread": 2, "messages": [
        ("ruth", 1, "19:40", "Anyone up for the wall this week?"),
        ("me", 1, "19:52", "Thursday after work?"),
        ("sam", 0, "08:31", "Thursday works. It's quiet after 7"),
        ("ruth", 0, "08:40", "I'll book the auto-belay slot"),
    ]},
    {"key": "design-review", "name": "#design-review", "network": "slackgo", "members": ["maya", "ben"],
     "unread": 1, "messages": [
        ("ben", 1, "16:20", "Pushed the new icons to the shared drive"),
        ("maya", 1, "16:31", "Thanks Ben, they look great"),
        ("maya", 0, "09:38", "could you look at the onboarding flow before standup?", {"mention": "me"}),
    ]},
    {"key": "jonas", "name": "Jonas Weber", "network": "telegram", "dm": True, "members": ["jonas"],
     "unread": 1, "messages": [
        ("me", 1, "17:45", "Safe flight ✈️"),
        ("jonas", 0, "09:27", "Landed in Berlin! Call you tonight?"),
    ]},
    {"key": "tom", "name": "Tom Becker", "network": "signal", "dm": True, "members": ["tom"],
     "seen": True, "messages": [
        ("tom", 0, "08:58", "Still on for 6 at the Crown?"),
        ("me", 0, "09:05", "Yes, see you there"),
    ]},
    {"key": "boardgames", "name": "Board game night", "network": "discordgo",
     "members": ["ines", "marco", "dev"], "avatar": ("🎲", (233, 225, 255)), "unread": 4, "messages": [
        ("ines", 1, "21:02", "Last week was so much fun"),
        ("ines", 0, "08:44", "Who's in for Friday?"),
        ("marco", 0, "08:47", "Me, I'll bring snacks"),
        ("dev", 0, "08:50", "In! Bringing the new expansion"),
        ("ines", 0, "08:52", "That's six of us 🎲"),
    ]},
    {"key": "lena", "name": "Lena Novak", "network": "instagramgo", "dm": True, "members": ["lena"],
     "messages": [
        ("lena", 0, "08:10", "haha this is so you 😂"),
        ("me", 0, "08:15", "Guilty as charged"),
    ]},
    {"key": "kofi", "name": "Kofi Mensah", "network": "whatsapp", "dm": True, "members": ["kofi"],
     "messages": [
        ("kofi", 1, "21:10", "Try the ramen place on Mill Road, it's great"),
        ("me", 1, "21:15", "Thanks for the recommendation!"),
    ]},
    {"key": "rust-london", "name": "Rust London", "network": "matrix", "members": ["iris", "oskar"],
     "avatar": ("🦀", (255, 226, 214)), "messages": [
        ("oskar", 1, "21:48", "Great talk tonight, thanks everyone"),
        ("iris", 1, "22:03", "Slides from tonight's talk are up on the meetup page"),
    ]},
    {"key": "grace", "name": "Grace Okafor", "network": "signal", "dm": True, "members": ["grace"],
     "messages": [
        ("grace", 2, "18:20", "Can you send me the address for Saturday?"),
        ("me", 2, "18:24", "Just sent it!"),
    ]},
    {"key": "general", "name": "#general", "network": "slackgo", "members": ["ben", "maya"],
     "messages": [
        ("ben", 3, "10:15", "Reminder: the office is closed on Friday"),
    ]},
]


def mention_content(key, text):
    name = PEOPLE[key][1] if key != "me" else "Alex Rivera"
    link = f"https://matrix.to/#/{mxid(key)}"
    return {
        "msgtype": "m.text",
        "body": f"{name} {text}",
        "format": "org.matrix.custom.html",
        "formatted_body": f'<a href="{link}">{name}</a> {text}',
        "m.mentions": {"user_ids": [mxid(key)]},
    }


def seed_chat(chat, pending):
    """Makes the chat and sends its messages, adding the unread ones to
    `pending` instead of sending them."""
    room = create_chat(chat)
    ids = []
    held = len(chat["messages"]) - chat.get("unread", 0)
    for i, msg in enumerate(chat["messages"]):
        sender, day, hhmm, text = msg[:4]
        opts = msg[4] if len(msg) > 4 else {}
        when = ts(day, hhmm)
        content = mention_content(opts["mention"], text) if "mention" in opts else {"msgtype": "m.text", "body": text}
        if "reply" in opts:
            content["m.relates_to"] = {"m.in_reply_to": {"event_id": ids[opts["reply"]]}}
        if i >= held:
            pending.append({"room": room, "sender": sender, "ts": when, "content": content})
            continue
        ids.append(send(room, sender, when, content))
        if "react" in opts:
            who, key = opts["react"]
            send(room, who, when + 60_000, {"m.relates_to": {
                "rel_type": "m.annotation", "event_id": ids[-1], "key": key}}, kind="m.reaction")
    receipt(room, "me", ids[-1])
    if chat.get("seen"):
        receipt(room, chat["members"][0], ids[-1])
    return room


def seed_chats():
    register_people()
    direct = {}
    pending = []
    for chat in CHATS:
        room = seed_chat(chat, pending)
        if chat.get("dm"):
            direct.setdefault(mxid(chat["members"][0]), []).append(room)
        if "favourite" in chat:
            call("PUT", f"/_matrix/client/v3/user/{urllib.parse.quote(ME)}/rooms/{urllib.parse.quote(room)}/tags/m.favourite",
                 {"order": chat["favourite"]}, as_user=ME)
        print(f"  {chat['name']:<20} {NETWORKS[chat['network']]:<10} {room}")
    call("PUT", f"/_matrix/client/v3/user/{urllib.parse.quote(ME)}/account_data/m.direct", direct, as_user=ME)
    with open(PENDING, "w") as f:
        json.dump(pending, f)


def send_unread():
    with open(PENDING) as f:
        pending = json.load(f)
    for m in pending:
        send(m["room"], m["sender"], m["ts"], m["content"])
    print(f"Sent {len(pending)} unread messages.")


if __name__ == "__main__":
    {"chats": seed_chats, "unread": send_unread}[MODE]()
