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
      expect(wa.logins.single.remoteName, '+44 7700 900123', reason: "the bridge's own name for the account");

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

    test('lists channels by server or workspace with the saved selection', () async {
      // As bridges/discord answers GET switchboard/v1/channels.
      replies['/bridges/discord/provision/switchboard/v1/channels?login_id=301+122'] = HubResponse(
        status: 200,
        body: jsonEncode({
          'groups': [
            {
              'id': 'g-atlas',
              'name': 'Atlas',
              'channels': [
                {'id': 'c1', 'name': 'general', 'selected': false},
              ],
            },
            {
              'id': 'g-harbour',
              'name': 'Harbour',
              'channels': [
                {'id': 'c2', 'name': 'general', 'selected': true},
                {'id': 'c3', 'name': 'build', 'section': 'Projects', 'selected': false},
              ],
            },
          ],
        }),
      );
      final groups = await hub.channels('discord', '301 122');
      expect(groups.map((g) => g.name), ['Atlas', 'Harbour']);
      expect(groups[1].channels.map((c) => (c.id, c.name, c.section, c.selected)), [
        ('c2', 'general', null, true),
        ('c3', 'build', 'Projects', false),
      ]);
      expect(calls.single.$1, 'GET');

      // As bridges/slack answers it: private channels are marked.
      replies['/bridges/slack/provision/switchboard/v1/channels?login_id=T1-U1'] = HubResponse(
        status: 200,
        body: '{"groups":[{"id":"T1","name":"Northwind","channels":'
            '[{"id":"C3","name":"leadership","private":true,"selected":true}]}]}',
      );
      final slack = await hub.channels('slack', 'T1-U1');
      expect(slack.single.channels.single.private, isTrue);
      expect(groups[0].channels.single.private, isFalse);
    });

    test('selecting puts and deselecting deletes the channel, returning what was saved', () async {
      const path = '/bridges/slack/provision/switchboard/v1/channels/T1/C%2F1?login_id=T1-U1';
      replies[path] = const HubResponse(status: 200, body: '{"group_id":"T1","id":"C/1","selected":true}');
      expect(await hub.setChannelBridged('slack', 'T1-U1', 'T1', 'C/1', bridged: true), isTrue);
      expect(calls.last, ('PUT', path, null));

      replies[path] = const HubResponse(status: 200, body: '{"group_id":"T1","id":"C/1","selected":false}');
      expect(await hub.setChannelBridged('slack', 'T1-U1', 'T1', 'C/1', bridged: false), isFalse);
      expect(calls.last, ('DELETE', path, null));
    });

    test('a channel change the bridge refuses or does not confirm is an error', () async {
      const path = '/bridges/slack/provision/switchboard/v1/channels/T1/C1?login_id=T1-U1';
      replies[path] = const HubResponse(
        status: 409,
        body: '{"errcode":"SWITCHBOARD_EVERY_CHANNEL_BRIDGED","error":"This bridge is set to bridge every channel"}',
      );
      await expectLater(
        hub.setChannelBridged('slack', 'T1-U1', 'T1', 'C1', bridged: false),
        throwsA(isA<HubException>()
            .having((e) => e.status, 'status', 409)
            .having((e) => e.code, 'code', 'SWITCHBOARD_EVERY_CHANNEL_BRIDGED')),
      );
      replies[path] = const HubResponse(status: 200, body: '');
      await expectLater(
        hub.setChannelBridged('slack', 'T1-U1', 'T1', 'C1', bridged: true),
        throwsA(isA<HubException>().having((e) => e.message, 'message', contains("didn't confirm"))),
      );
    });

    test('only Discord and Slack bridges have channels to choose', () {
      Bridge b(String id, {String? type, bool api = true}) =>
          Bridge(id: id, network: id, reachable: true, supportsApi: api, networkId: type);
      expect(b('discord', type: 'discordgo').hasChannels, isTrue);
      expect(b('slack', type: 'slackgo').hasChannels, isTrue);
      expect(b('work-chat', type: 'slack').hasChannels, isTrue);
      expect(b('discord').hasChannels, isTrue);
      expect(b('discord', api: false).hasChannels, isFalse, reason: 'a legacy bot bridge has no API to ask');
      expect(b('whatsapp', type: 'whatsapp').hasChannels, isFalse);
      expect(b('signal').hasChannels, isFalse);
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
