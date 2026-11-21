#!/usr/bin/env python3
"""Stand-ins for the bridges' provisioning APIs, for the demo backend.

The Hub asks each bridge's /_matrix/provision/v3/whoami for its network and
logins; these answer with fictional accounts, so the app's Accounts screen,
view switcher and Add account list have something to show. Slack and Discord
also answer the channel selection endpoints of bridges/slack and
bridges/discord, keeping the selection in memory, for Settings > Channels.
Nothing here talks to a real network.

    fake_bridges.py serve DOMAIN FIRST_PORT
    fake_bridges.py hub-config OWNER_MXID HOMESERVER_URL LISTEN FIRST_PORT

Bridge i listens on 127.0.0.1:FIRST_PORT+i, in the order of BRIDGES;
hub-config prints a hub.yaml that lists them.
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# id, display name, network ID, bridge type, logins, login flows. The phone
# numbers are in Ofcom's 07700 900xxx range, kept for drama and fiction.
BRIDGES = [
    ("whatsapp", "WhatsApp", "whatsapp", "whatsapp",
     [{"id": "447700900123", "name": "Alex Rivera", "profile": {"phone": "+44 7700 900123"}}],
     [("qr", "QR", "Scan a QR code to pair the bridge to your WhatsApp app"),
      ("phone", "Pairing code", "Input your phone number to get a pairing code, to pair the bridge to your WhatsApp app")]),
    ("signal", "Signal", "signal", "signal",
     [{"id": "5f0c2a1e", "name": "Alex Rivera", "profile": {"phone": "+44 7700 900456"}}],
     [("qr", "QR", "Scan a QR code to link the bridge as a secondary device")]),
    ("telegram", "Telegram", "telegram", "telegram",
     [{"id": "48213377", "name": "Alex Rivera", "profile": {"username": "alexrivera"}}],
     [("phone", "Phone number", "Log in with your phone number"),
      ("qr", "QR", "Scan a QR code from the Telegram app")]),
    ("slack", "Slack", "slack", "slackgo",
     [{"id": "T0NWIND-U04ALEX", "name": "Northwind", "profile": {"email": "alex@northwind.example"}}],
     [("cookies", "Cookies", "Log in to Slack in a web view"),
      ("token", "Token", "Log in with a Slack token")]),
    ("discord", "Discord", "discord", "discordgo",
     [{"id": "301122334455", "name": "Alex Rivera", "profile": {"username": "alexr"}}],
     [("browser", "Browser", "Log in through the Discord website"),
      ("qr", "QR", "Scan a QR code with the Discord app")]),
    ("instagram", "Instagram", "instagram", "instagramgo",
     [{"id": "17841400000", "name": "Alex Rivera", "profile": {"username": "alex.rivera"}}],
     [("cookies", "Cookies", "Log in to Instagram in a web view")]),
    ("matrix", "Matrix", "matrix", "matrix",
     [{"id": "alex-matrix", "name": "Alex Rivera", "profile": {"username": "alex:matrix.example.org"}}],
     [("password", "Password", "Sign in with your homeserver, username and password")]),
]

# Bridge id to login id to that account's servers or workspaces: (id, name,
# channels), each channel (id, name, section, private, selected). Two of the
# Discord servers have a #general, as real ones do.
CHANNELS = {
    "slack": {"T0NWIND-U04ALEX": [
        ("T0NWIND", "Northwind", [
            ("C01", "announcements", None, False, True),
            ("C02", "design", None, False, True),
            ("C03", "general", None, False, False),
            ("C04", "leadership", None, True, False),
            ("C05", "random", None, False, False),
        ]),
    ]},
    "discord": {"301122334455": [
        ("9001", "Harbour Sailing Club", [
            ("9101", "general", None, False, False),
            ("9102", "race-days", "Events", False, True),
            ("9103", "boat-maintenance", "Workshop", False, False),
        ]),
        ("9002", "Pixel Pushers", [
            ("9201", "general", None, False, False),
            ("9202", "show-and-tell", None, False, False),
        ]),
    ]},
}
CHANNELS_PATH = "/_matrix/provision/switchboard/v1/channels"


def handler_for(bridge, domain):
    bid, display, network_id, bridge_type, logins, flows = bridge
    now = int(time.time() * 1000)
    whoami = {
        "network": {
            "displayname": display,
            "network_id": network_id,
            "beeper_bridge_type": bridge_type,
        },
        "login_flows": [{"id": f, "name": n, "description": d} for f, n, d in flows],
        "homeserver": domain,
        "bridge_bot": f"@{bid}bot:{domain}",
        "command_prefix": f"!{bid}",
        "logins": [
            dict(login, state={"state_event": "CONNECTED", "timestamp": now // 1000})
            for login in logins
        ],
    }
    routes = {
        "/_matrix/provision/v3/whoami": whoami,
        "/_matrix/provision/v3/login/flows": {"flows": whoami["login_flows"]},
    }
    # login id -> {(group id, channel id): selected}, changed by PUT and DELETE.
    selection = {
        login_id: {(gid, cid): on for gid, _, chans in groups for cid, _, _, _, on in chans}
        for login_id, groups in CHANNELS.get(bid, {}).items()
    }

    def list_channels(login_id):
        return {"groups": [
            {"id": gid, "name": name, "channels": [
                {"id": cid, "name": cname, "selected": selection[login_id][(gid, cid)],
                 **({"section": section} if section else {}), **({"private": True} if private else {})}
                for cid, cname, section, private, _ in chans
            ]}
            for gid, name, chans in CHANNELS[bid][login_id]
        ]}

    class Handler(BaseHTTPRequestHandler):
        def _send(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _login(self):
            """The login a channel request names; answers 404 if there is none."""
            url = urlparse(self.path)
            login_id = parse_qs(url.query).get("login_id", [""])[0]
            if not url.path.startswith(CHANNELS_PATH) or bid not in CHANNELS:
                self._send(404, {"errcode": "M_UNRECOGNIZED", "error": "not in the demo"})
            elif login_id not in selection:
                self._send(404, {"errcode": "M_NOT_FOUND", "error": "Login not found"})
            else:
                return login_id
            return None

        def _select(self, selected):
            login_id = self._login()
            if login_id is None:
                return
            key = tuple(urlparse(self.path).path[len(CHANNELS_PATH):].strip("/").split("/"))
            if key not in selection[login_id]:
                self._send(404, {"errcode": "M_NOT_FOUND", "error": "This account can't see that channel"})
                return
            selection[login_id][key] = selected
            self._send(200, {"group_id": key[0], "id": key[1], "selected": selected})

        def do_GET(self):
            path = urlparse(self.path).path
            if path == CHANNELS_PATH and bid in CHANNELS:
                login_id = self._login()
                if login_id is not None:
                    self._send(200, list_channels(login_id))
                return
            body = routes.get(path)
            if body is None:
                self._send(404, {"errcode": "M_NOT_FOUND", "error": "not in the demo"})
            else:
                self._send(200, body)

        def do_PUT(self):
            self._select(True)

        def do_DELETE(self):
            self._select(False)

        def do_POST(self):
            self._send(400, {"errcode": "M_UNKNOWN", "error": "The demo backend can't link accounts"})

        def log_message(self, *args):
            pass

    return Handler


def hub_config(owner, homeserver, listen, first_port):
    print(f'listen: "{listen}"')
    print(f'owner: "{owner}"')
    print(f"homeserver: {homeserver}")
    print("bridges:")
    for i, (bid, display, *_rest) in enumerate(BRIDGES):
        print(f"  - id: {bid}\n    network: {display}\n    kind: bridgev2\n"
              f"    url: http://127.0.0.1:{first_port + i}")


def serve(domain, first_port):
    servers = []
    for i, bridge in enumerate(BRIDGES):
        srv = ThreadingHTTPServer(("127.0.0.1", first_port + i), handler_for(bridge, domain))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        servers.append(srv)
    print(f"fake bridges on 127.0.0.1:{first_port}-{first_port + len(BRIDGES) - 1}", flush=True)
    threading.Event().wait()


if __name__ == "__main__":
    if sys.argv[1:2] == ["serve"]:
        serve(sys.argv[2], int(sys.argv[3]))
    elif sys.argv[1:2] == ["hub-config"]:
        hub_config(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]))
    else:
        sys.exit(__doc__)
