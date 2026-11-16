import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/hub.dart';

// Captured from the Hub on 30 October 2026, with no accounts linked.
const bridgesJson = '''
{"bridges":[
 {"id":"signal","network":"Signal","kind":"bridgev2","provisioning":"api","reachable":true,
  "whoami":{"network":{"displayname":"Signal","network_icon":"mxc://maunium.net/wPJgTQbZOtpBFmDNkiNEMDUp","network_id":"signal"},
   "login_flows":[{"name":"QR","description":"Scan a QR code to pair the bridge to your Signal app","id":"qr"}],
   "bridge_bot":"@signalbot:switchboard.internal","logins":[]},"states":[]},
 {"id":"whatsapp","network":"WhatsApp","kind":"bridgev2","provisioning":"api","reachable":true,
  "whoami":{"network":{"displayname":"WhatsApp","network_icon":"mxc://maunium.net/NeXNQarUbrlYBiPCpprYsRqr","network_id":"whatsapp"},
   "login_flows":[{"name":"QR","description":"Scan a QR code","id":"qr"},{"name":"Pairing code","description":"Input your phone number","id":"phone"}],
   "logins":[{"id":"447700900123","name":"+44 7700 900123","state":{"state_event":"CONNECTED","timestamp":1761800000},
     "profile":{"phone":"+447700900123","name":"Richard"}}]},"states":[]},
 {"id":"discord","network":"Discord","kind":"legacy","provisioning":"bot","reachable":false,"states":[]}
]}''';

void main() {
  group('HubApi', () {
    late List<(String, String, String?)> calls;
    late Map<String, HubResponse> replies;
    late HubApi hub;

    setUp(() {
      calls = [];
      replies = {};
      hub = HubApi((method, path, body) async {
        calls.add((method, path, body));
        return replies[path] ?? HubResponse(status: 404, body: '{"errcode":"M_NOT_FOUND","error":"no route"}');
      });
    });

    test('parses bridges, flows and logins', () async {
      replies['/bridges'] = HubResponse(status: 200, body: bridgesJson);
      final bridges = await hub.bridges();
      expect(bridges.map((b) => b.id), ['signal', 'whatsapp', 'discord']);

      final wa = bridges[1];
      expect(wa.network, 'WhatsApp');
      expect(wa.iconMxc, startsWith('mxc://'));
      expect(wa.flows.map((f) => f.id), ['qr', 'phone']);
      expect(wa.logins.single.state, 'CONNECTED');
      expect(wa.logins.single.name, 'Richard');
      expect(wa.logins.single.handle, '+447700900123');

      expect(bridges[2].supportsApi, isFalse);
      expect(bridges[2].reachable, isFalse);
    });

    test('start, wait and submit use the provisioning paths', () async {
      replies['/bridges/whatsapp/provision/v3/login/start/qr'] = HubResponse(
        status: 200,
        body: jsonEncode({
          'login_id': 'L1',
          'type': 'display_and_wait',
          'step_id': 'fi.mau.whatsapp.qr',
          'instructions': 'Scan the QR code',
          'display_and_wait': {'type': 'qr', 'data': '2@abc,def'},
        }),
      );
      replies['/bridges/whatsapp/provision/v3/login/step/L1/fi.mau.whatsapp.qr/display_and_wait'] = HubResponse(
        status: 200,
        body: jsonEncode({
          'login_id': 'L1',
          'type': 'complete',
          'step_id': 'fi.mau.whatsapp.complete',
          'complete': {'user_login_id': '447700900123'},
        }),
      );

      final step = await hub.start('whatsapp', 'qr');
      expect(step.type, 'display_and_wait');
      expect(step.displayType, 'qr');
      expect(step.displayData, '2@abc,def');

      final done = await hub.wait('whatsapp', step);
      expect(done.type, 'complete');
      expect(done.userLoginId, '447700900123');
      expect(calls.map((c) => c.$1), everyElement('POST'));
    });

    test('relink passes the login ID', () async {
      await expectLater(hub.start('signal', 'qr', loginId: 'abc def'), throwsA(isA<HubException>()));
      expect(calls.single.$2, '/bridges/signal/provision/v3/login/start/qr?login_id=abc+def');
    });

    test('errors carry the bridge message', () async {
      await expectLater(
        hub.bridges(),
        throwsA(isA<HubException>().having((e) => e.message, 'message', 'no route').having((e) => e.status, 'status', 404)),
      );
    });

    test('parses user_input fields', () {
      final step = LoginStep.fromJson({
        'login_id': 'L2',
        'type': 'user_input',
        'step_id': 'fi.mau.whatsapp.login.phone',
        'instructions': 'Enter your phone number',
        'user_input': {
          'fields': [
            {'type': 'phone_number', 'id': 'phone_number', 'name': 'Phone number', 'pattern': r'^\+\d+$'},
            {'type': 'select', 'id': 'device', 'name': 'Device', 'options': ['a', 'b']},
          ],
        },
      });
      expect(step.fields.map((f) => f.type), ['phone_number', 'select']);
      expect(step.fields.first.pattern, r'^\+\d+$');
      expect(step.fields.last.options, ['a', 'b']);
    });
  });

  group('account problems', () {
    BridgeLogin login(String state) => BridgeLogin(id: state, name: state, state: state);
    Bridge bridge(String name, {bool reachable = true, List<BridgeLogin> logins = const []}) =>
        Bridge(id: name.toLowerCase(), network: name, reachable: reachable, supportsApi: true, logins: logins);

    test('relink, errors and dead bridges are flagged; healthy and transient states are not', () {
      final problems = accountProblems([
        bridge('WhatsApp', logins: [login('CONNECTED'), login('BAD_CREDENTIALS')]),
        bridge('Signal', logins: [login('TRANSIENT_DISCONNECT'), login('UNKNOWN_ERROR')]),
        bridge('Telegram', reachable: false),
      ]);
      expect(problems.map((p) => p.message), [
        'WhatsApp needs relinking',
        'Signal has a problem',
        "Telegram isn't responding",
      ]);
    });

    test('a legacy bot bridge is not reported as down', () {
      final legacy = Bridge(id: 'discord', network: 'Discord', reachable: false, supportsApi: false);
      expect(accountProblems([legacy]), isEmpty);
    });

    test("a network's status dot is its worst login, and red when the bridge is down", () {
      Health? health(List<BridgeLogin> logins, {bool reachable = true}) =>
          networkHealth([bridge('WhatsApp', reachable: reachable, logins: logins)], 'whatsapp');
      expect(health([]), isNull);
      expect(health([login('CONNECTED'), login('BACKFILLING')]), Health.connected);
      expect(health([login('CONNECTED'), login('TRANSIENT_DISCONNECT')]), Health.reconnecting);
      expect(health([login('CONNECTING'), login('LOGGED_OUT')]), Health.broken);
      expect(health([login('CONNECTED')], reachable: false), Health.broken);
      expect(networkHealth([bridge('WhatsApp', logins: [login('BAD_CREDENTIALS')])], 'signal'), isNull);
    });
  });
}
