import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/hub.dart';
import 'package:switchboard/src/ui/channels_screen.dart';

Bridge bridge(String id, String network, List<BridgeLogin> logins) => Bridge(
      id: id,
      network: network,
      reachable: true,
      supportsApi: true,
      networkId: '${id}go',
      logins: logins,
    );

BridgeLogin login(String id, String name) => BridgeLogin(id: id, name: name, state: 'CONNECTED');

final discord = bridge('discord', 'Discord', [login('301', 'Alex Rivera')]);
final slack = bridge('slack', 'Slack', [login('T1-U1', 'Northwind'), login('T2-U9', 'Atlas Labs')]);
final whatsapp = bridge('whatsapp', 'WhatsApp', [login('447700900123', 'Alex')]);

/// The bridges' channel endpoints as bridges/discord and bridges/slack
/// answer them, holding the selection the way the bridges do: per login,
/// outliving the screen and the app.
class FakeBridges {
  FakeBridges();

  final calls = <(String, String)>[];

  /// "bridge/login" to its groups: (group ID, group name, channels as
  /// (ID, name, section, private)).
  final groups = <String, List<(String, String, List<(String, String, String?, bool)>)>>{
    'discord/301': [
      ('g-atlas', 'Atlas', [('c-a-general', 'general', null, false)]),
      (
        'g-harbour',
        'Harbour',
        [('c-h-general', 'general', null, false), ('c-h-build', 'build', 'Projects', false)],
      ),
    ],
    'slack/T1-U1': [
      ('T1', 'Northwind', [('C1', 'general', null, false), ('C3', 'leadership', null, true)]),
    ],
    'slack/T2-U9': [
      ('T2', 'Atlas Labs', [('C1', 'general', null, false)]),
    ],
  };

  /// "bridge/login" to its selected channel IDs.
  final selected = <String, Set<String>>{
    'slack/T2-U9': {'C1'},
  };

  /// Path suffixes that answer with a scripted response instead: an error
  /// (status, body), a [Completer] to wait on, or an [Exception] to throw.
  final scripted = <String, Object>{};

  Future<HubResponse> send(String method, String path, String? body) async {
    calls.add((method, path));
    final uri = Uri.parse(path);
    final script = scripted.entries.where((e) => uri.path.endsWith(e.key)).map((e) => e.value).firstOrNull;
    if (script is Exception) throw script;
    if (script is Completer<void>) await script.future;
    if (script is (int, String)) return HubResponse(status: script.$1, body: script.$2);

    final parts = uri.pathSegments; // bridges/<id>/provision/switchboard/v1/channels[/group/channel]
    final account = '${parts[1]}/${uri.queryParameters['login_id']}';
    final mine = groups[account];
    if (mine == null) {
      return const HubResponse(status: 404, body: '{"errcode":"M_NOT_FOUND","error":"Login not found"}');
    }
    final on = selected.putIfAbsent(account, () => {});
    if (method == 'GET') {
      return HubResponse(
        status: 200,
        body: jsonEncode({
          'groups': [
            for (final (id, name, channels) in mine)
              {
                'id': id,
                'name': name,
                'channels': [
                  for (final (cid, cname, section, private) in channels)
                    {
                      'id': cid,
                      'name': cname,
                      'section': ?section,
                      if (private) 'private': true,
                      'selected': on.contains(cid),
                    },
                ],
              },
          ],
        }),
      );
    }
    final (group, channel) = (parts[6], parts[7]);
    final known = mine.any((g) => g.$1 == group && g.$3.any((c) => c.$1 == channel));
    if (method == 'PUT' && !known) {
      return const HubResponse(
        status: 404,
        body: '{"errcode":"M_NOT_FOUND","error":"This account can\'t see that channel"}',
      );
    }
    method == 'PUT' ? on.add(channel) : on.remove(channel);
    return HubResponse(
      status: 200,
      body: jsonEncode({'group_id': group, 'id': channel, 'selected': method == 'PUT'}),
    );
  }
}

Widget app(FakeBridges hub, {List<Bridge>? bridges}) => ProviderScope(
      overrides: [
        hubProvider.overrideWithValue(HubApi(hub.send)),
        bridgesProvider.overrideWith((ref) async => bridges ?? [whatsapp, discord, slack]),
      ],
      child: const MaterialApp(home: ChannelsScreen()),
    );

/// Screens with a spinner never settle; pump a few frames instead.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The switch of the channel with this "group/channel" key.
SwitchListTile channelSwitch(WidgetTester tester, String key) =>
    tester.widget<SwitchListTile>(find.byKey(ValueKey(key)));

Future<void> tapChannel(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(key)));
}

Future<void> expand(WidgetTester tester, String group) async {
  await tester.ensureVisible(find.text(group));
  await tester.pump();
  await tester.tap(find.text(group));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.physicalSize = const Size(500, 2400);
    view.devicePixelRatio = 1;
    addTearDown(view.reset);
  });

  testWidgets('lists each linked Discord and Slack account with its channels by server or workspace',
      (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();

    // One section per linked account; WhatsApp has no channels to choose.
    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.text('Northwind'), findsNWidgets(2), reason: 'the account and its workspace');
    expect(find.text('Atlas Labs'), findsNWidgets(2));
    expect(find.text('Alex'), findsNothing);
    expect(
      hub.calls.map((c) => c.$2),
      containsAll([
        '/bridges/discord/provision/switchboard/v1/channels?login_id=301',
        '/bridges/slack/provision/switchboard/v1/channels?login_id=T1-U1',
        '/bridges/slack/provision/switchboard/v1/channels?login_id=T2-U9',
      ]),
    );

    // Workspaces with one group open by themselves; so does a group with a
    // channel on. Discord's two servers start closed and say what's on.
    expect(find.text('Atlas'), findsOneWidget);
    expect(find.text('Harbour'), findsOneWidget);
    expect(find.text('None of 1 on'), findsOneWidget);
    expect(find.text('None of 2 on'), findsNWidgets(2));
    expect(find.text('1 of 1 on'), findsOneWidget);
    expect(channelSwitch(tester, 'T2/C1').value, isTrue, reason: 'the saved selection');
    expect(channelSwitch(tester, 'T1/C1').value, isFalse);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget, reason: 'the private channel');

    // Both servers have a #general; each sits under its own server.
    await expand(tester, 'Atlas');
    await expand(tester, 'Harbour');
    expect(find.byKey(const ValueKey('g-atlas/c-a-general')), findsOneWidget);
    expect(find.byKey(const ValueKey('g-harbour/c-h-general')), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget, reason: "the channel's category");
  });

  testWidgets('selecting shows as on only once the bridge has saved it; deselecting likewise', (tester) async {
    final hub = FakeBridges();
    final saving = Completer<void>();
    hub.scripted['/T1/C1'] = saving;
    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();

    await tapChannel(tester, 'T1/C1');
    await settle(tester);
    // On its way: not shown as on, and it can't be tapped again.
    expect(channelSwitch(tester, 'T1/C1').value, isFalse);
    expect(channelSwitch(tester, 'T1/C1').onChanged, isNull);
    expect(hub.calls.last, ('PUT', '/bridges/slack/provision/switchboard/v1/channels/T1/C1?login_id=T1-U1'));

    hub.scripted.clear();
    saving.complete();
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'T1/C1').value, isTrue);
    expect(find.text('1 of 2 on'), findsOneWidget);
    expect(hub.selected['slack/T1-U1'], {'C1'});

    await tapChannel(tester, 'T1/C1');
    await tester.pumpAndSettle();
    expect(hub.calls.last, ('DELETE', '/bridges/slack/provision/switchboard/v1/channels/T1/C1?login_id=T1-U1'));
    expect(channelSwitch(tester, 'T1/C1').value, isFalse);
    expect(hub.selected['slack/T1-U1'], isEmpty);

    // Another account's selection is its own.
    expect(hub.selected['slack/T2-U9'], {'C1'});
    expect(channelSwitch(tester, 'T2/C1').value, isTrue);
  });

  testWidgets('Discord channels select through the same flow', (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();
    await expand(tester, 'Harbour');

    await tapChannel(tester, 'g-harbour/c-h-build');
    await tester.pumpAndSettle();
    expect(
      hub.calls.last,
      ('PUT', '/bridges/discord/provision/switchboard/v1/channels/g-harbour/c-h-build?login_id=301'),
    );
    expect(channelSwitch(tester, 'g-harbour/c-h-build').value, isTrue);
    expect(channelSwitch(tester, 'g-harbour/c-h-general').value, isFalse);

    await tapChannel(tester, 'g-harbour/c-h-build');
    await tester.pumpAndSettle();
    expect(hub.calls.last.$1, 'DELETE');
    expect(channelSwitch(tester, 'g-harbour/c-h-build').value, isFalse);
  });

  testWidgets('a rejected or failed change says so and leaves the saved selection showing', (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();

    // Rejected by the bridge.
    hub.scripted['/T1/C1'] = (404, '{"errcode":"M_NOT_FOUND","error":"This account isn\'t in that channel"}');
    await tapChannel(tester, 'T1/C1');
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'T1/C1').value, isFalse);
    expect(find.text("Couldn't turn on: This account isn't in that channel"), findsOneWidget);
    expect(find.text("Couldn't turn on general: This account isn't in that channel"), findsOneWidget);

    // The save failed.
    hub.scripted['/T2/C1'] = (500, '{"errcode":"M_UNKNOWN","error":"Couldn\'t save the selection"}');
    await tapChannel(tester, 'T2/C1');
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'T2/C1').value, isTrue, reason: 'still on: turning it off was not saved');
    expect(find.text("Couldn't turn off: Couldn't save the selection"), findsOneWidget);

    // The server couldn't be reached.
    hub.scripted['/T1/C3'] = Exception('connection refused');
    await tapChannel(tester, 'T1/C3');
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'T1/C3').value, isFalse);
    expect(find.textContaining("Couldn't turn on: Exception: connection refused"), findsOneWidget);

    // An answer that doesn't confirm anything isn't taken as saved.
    hub.scripted['/T1/C3'] = (200, '{}');
    await tapChannel(tester, 'T1/C3');
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'T1/C3').value, isFalse);
    expect(find.textContaining("The bridge didn't confirm the change"), findsWidgets);
    expect(hub.selected['slack/T1-U1'] ?? <String>{}, isEmpty);

    // Trying again once it works clears the error.
    hub.scripted.clear();
    await tapChannel(tester, 'T1/C1');
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'T1/C1').value, isTrue);
    expect(find.text("Couldn't turn on: This account isn't in that channel"), findsNothing);
  });

  testWidgets('the saved selection shows again after reopening Settings and after a relaunch', (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();
    await tapChannel(tester, 'T1/C3');
    await tester.pumpAndSettle();
    await expand(tester, 'Atlas');
    await tapChannel(tester, 'g-atlas/c-a-general');
    await tester.pumpAndSettle();

    // Leave Settings and come back: fetched from the bridges again.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    hub.calls.clear();
    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();
    expect(hub.calls.where((c) => c.$1 == 'GET'), hasLength(3));
    expect(channelSwitch(tester, 'T1/C3').value, isTrue);
    expect(channelSwitch(tester, 'T1/C1').value, isFalse);
    expect(channelSwitch(tester, 'g-atlas/c-a-general').value, isTrue, reason: 'open, as it has a channel on');
    expect(channelSwitch(tester, 'T2/C1').value, isTrue, reason: "the other account's selection is untouched");

    // A relaunch starts with nothing in memory: a new provider scope.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: app(hub)));
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'T1/C3').value, isTrue);
    expect(channelSwitch(tester, 'g-atlas/c-a-general').value, isTrue);
    expect(channelSwitch(tester, 'T2/C1').value, isTrue);
  });

  testWidgets('loading, empty and failed lists each say what is happening', (tester) async {
    final hub = FakeBridges();
    final loading = Completer<void>();
    hub.scripted['/discord/provision/switchboard/v1/channels'] = loading;
    hub.scripted['/slack/provision/switchboard/v1/channels'] = (502, '{"errcode":"M_UNKNOWN","error":"ratelimited"}');
    hub.groups['discord/301'] = [];
    await tester.pumpWidget(app(hub));
    await settle(tester);

    expect(find.text('Loading channels…'), findsOneWidget);
    expect(find.text("Couldn't load channels: ratelimited"), findsNWidgets(2));

    // Discord answers: the account is in no server with channels to show.
    loading.complete();
    hub.scripted.remove('/discord/provision/switchboard/v1/channels');
    await tester.pumpAndSettle();
    expect(find.text('Loading channels…'), findsNothing);
    expect(find.textContaining('No channels yet. Text channels this account can see'), findsOneWidget);

    // Slack recovers; trying again fetches the list.
    hub.scripted.clear();
    await tester.tap(find.text('Try again').first);
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load channels: ratelimited"), findsOneWidget);
    expect(find.byKey(const ValueKey('T1/C1')), findsOneWidget);
  });

  testWidgets('a bridge from before channel selection says the server needs updating', (tester) async {
    final hub = FakeBridges();
    hub.scripted['/discord/provision/switchboard/v1/channels'] = (404, '404 page not found');
    await tester.pumpWidget(app(hub, bridges: [discord]));
    await tester.pumpAndSettle();
    expect(find.textContaining("This server's Discord bridge can't choose channels yet"), findsOneWidget);
  });

  testWidgets('with no Discord or Slack account linked it says so and offers to add one', (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub, bridges: [whatsapp, bridge('slack', 'Slack', [])]));
    await tester.pumpAndSettle();
    expect(find.textContaining('No Discord or Slack account linked.'), findsOneWidget);
    expect(find.text('Add account'), findsOneWidget);
    expect(hub.calls, isEmpty);
  });

  testWidgets('while accounts load it shows progress, and a failure offers to try again', (tester) async {
    final accounts = Completer<List<Bridge>>();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hubProvider.overrideWithValue(HubApi(FakeBridges().send)),
        bridgesProvider.overrideWith((ref) => accounts.future),
      ],
      child: const MaterialApp(home: ChannelsScreen()),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    accounts.completeError(HubException('the Hub is unreachable'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load accounts: the Hub is unreachable"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
