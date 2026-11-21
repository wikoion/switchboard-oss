import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

BridgeLogin login(String id, String name, {String? remoteName, String? email}) =>
    BridgeLogin(id: id, name: name, state: 'CONNECTED', remoteName: remoteName, email: email);

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

/// The account picker, or with [account] ("bridge/login") that account's
/// own page.
Widget app(FakeBridges hub, {List<Bridge>? bridges, String? account}) => ProviderScope(
      overrides: [
        hubProvider.overrideWithValue(HubApi(hub.send)),
        bridgesProvider.overrideWith((ref) async => bridges ?? [whatsapp, discord, slack]),
      ],
      child: MaterialApp(
        home: account == null
            ? const ChannelsScreen()
            : AccountChannelsScreen(bridgeId: account.split('/')[0], loginId: account.split('/')[1]),
      ),
    );

/// The picker and the account pages under the app's own paths.
Widget routedApp(FakeBridges hub, {List<Bridge>? bridges}) => ProviderScope(
      overrides: [
        hubProvider.overrideWithValue(HubApi(hub.send)),
        bridgesProvider.overrideWith((ref) async => bridges ?? [whatsapp, discord, slack]),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/settings/channels',
          routes: [
            GoRoute(
              path: '/settings/channels',
              builder: (_, _) => const ChannelsScreen(),
              routes: [
                GoRoute(
                  path: ':bridge/:login',
                  builder: (_, s) => AccountChannelsScreen(
                    bridgeId: s.pathParameters['bridge']!,
                    loginId: s.pathParameters['login']!,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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

  testWidgets('lists each linked Discord and Slack account without asking for any channels', (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();

    // One row per linked account; WhatsApp has no channels to choose.
    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.text('Northwind'), findsOneWidget);
    expect(find.text('Atlas Labs'), findsOneWidget);
    expect(find.text('Alex'), findsNothing);
    expect(find.text('Discord'), findsOneWidget);
    expect(find.text('Slack'), findsNWidgets(2));
    expect(find.byIcon(Icons.chevron_right_rounded), findsNWidgets(3));

    // The channels wait for the account's own page.
    expect(find.byType(SwitchListTile), findsNothing);
    expect(hub.calls, isEmpty);
  });

  testWidgets('tapping an account opens its own page of channels', (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(routedApp(hub));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Atlas Labs'));
    await tester.pumpAndSettle();
    expect(find.text('Slack channels'), findsOneWidget);
    expect(find.byKey(const ValueKey('T2/C1')), findsOneWidget);
    expect(hub.calls, [('GET', '/bridges/slack/provision/switchboard/v1/channels?login_id=T2-U9')]);
  });

  test('an account page path encodes the bridge and login', () {
    expect(accountChannelsPath('slack', 'T1-U1'), '/settings/channels/slack/T1-U1');
    expect(accountChannelsPath('work chat', '301/122'), '/settings/channels/work%20chat/301%2F122');
  });

  testWidgets("two accounts with the same profile are told apart by the bridge's name for each", (tester) async {
    final twins = bridge('slack', 'Slack', [
      login('T1-U1', 'Alex Rivera', remoteName: 'Northwind - alex@example.com', email: 'alex@example.com'),
      login('T2-U9', 'Alex Rivera', remoteName: 'Atlas Labs - alex@example.com', email: 'alex@example.com'),
    ]);
    // Without one, or with one that only repeats the name, the handle shows.
    final plain = bridge('discord', 'Discord', [
      login('301', 'Alex Rivera', remoteName: 'Alex Rivera', email: 'alex@example.com'),
    ]);
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub, bridges: [twins, plain]));
    await tester.pumpAndSettle();
    expect(find.text('Slack · Northwind - alex@example.com'), findsOneWidget);
    expect(find.text('Slack · Atlas Labs - alex@example.com'), findsOneWidget);
    expect(find.text('Discord · alex@example.com'), findsOneWidget);

    // The account's page says the same at the top.
    await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: app(hub, bridges: [twins], account: 'slack/T2-U9')));
    await tester.pumpAndSettle();
    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.text('Slack · Atlas Labs - alex@example.com'), findsOneWidget);
  });

  testWidgets("an account's page shows only its own servers or workspaces and their channels", (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub, account: 'discord/301'));
    await tester.pumpAndSettle();

    expect(find.text('Discord channels'), findsOneWidget);
    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.text('Northwind'), findsNothing);
    expect(find.text('Atlas Labs'), findsNothing);
    expect(hub.calls.map((c) => c.$2), ['/bridges/discord/provision/switchboard/v1/channels?login_id=301']);

    // Discord's two servers start closed and say what's on.
    expect(find.text('Atlas'), findsOneWidget);
    expect(find.text('Harbour'), findsOneWidget);
    expect(find.text('None of 1 on'), findsOneWidget);
    expect(find.text('None of 2 on'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);

    // Both servers have a #general; each sits under its own server.
    await expand(tester, 'Atlas');
    await expand(tester, 'Harbour');
    expect(find.byKey(const ValueKey('g-atlas/c-a-general')), findsOneWidget);
    expect(find.byKey(const ValueKey('g-harbour/c-h-general')), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget, reason: "the channel's category");

    // A workspace by itself opens, showing the saved selection.
    await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: app(hub, account: 'slack/T2-U9')));
    await tester.pumpAndSettle();
    expect(find.text('Slack channels'), findsOneWidget);
    expect(find.text('Atlas Labs'), findsNWidgets(2), reason: 'the account and its workspace');
    expect(find.text('Northwind'), findsNothing);
    expect(find.text('1 of 1 on'), findsOneWidget);
    expect(channelSwitch(tester, 'T2/C1').value, isTrue, reason: 'the saved selection');

    await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: app(hub, account: 'slack/T1-U1')));
    await tester.pumpAndSettle();
    expect(find.text('None of 2 on'), findsOneWidget);
    expect(channelSwitch(tester, 'T1/C1').value, isFalse);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget, reason: 'the private channel');
    expect(find.byKey(const ValueKey('T2/C1')), findsNothing);
  });

  testWidgets("an account that isn't linked any more says so", (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub, account: 'slack/T9-U9'));
    await tester.pumpAndSettle();
    expect(find.text("This account isn't linked any more."), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(hub.calls, isEmpty);
  });

  testWidgets('selecting shows as on only once the bridge has saved it; deselecting likewise', (tester) async {
    final hub = FakeBridges();
    final saving = Completer<void>();
    hub.scripted['/T1/C1'] = saving;
    await tester.pumpWidget(app(hub, account: 'slack/T1-U1'));
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
  });

  testWidgets('Discord channels select through the same flow', (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub, account: 'discord/301'));
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
    await tester.pumpWidget(app(hub, account: 'slack/T1-U1'));
    await tester.pumpAndSettle();

    // Rejected by the bridge.
    hub.scripted['/T1/C1'] = (404, '{"errcode":"M_NOT_FOUND","error":"This account isn\'t in that channel"}');
    await tapChannel(tester, 'T1/C1');
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'T1/C1').value, isFalse);
    expect(find.text("Couldn't turn on: This account isn't in that channel"), findsOneWidget);
    expect(find.text("Couldn't turn on general: This account isn't in that channel"), findsOneWidget);

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

    // A save that fails leaves a channel that was on showing as on.
    await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: app(hub, account: 'slack/T2-U9')));
    await tester.pumpAndSettle();
    hub.scripted['/T2/C1'] = (500, '{"errcode":"M_UNKNOWN","error":"Couldn\'t save the selection"}');
    await tapChannel(tester, 'T2/C1');
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'T2/C1').value, isTrue, reason: 'still on: turning it off was not saved');
    expect(find.text("Couldn't turn off: Couldn't save the selection"), findsOneWidget);
  });

  testWidgets('the saved selection shows again after reopening Settings and after a relaunch', (tester) async {
    final hub = FakeBridges();
    await tester.pumpWidget(app(hub, account: 'slack/T1-U1'));
    await tester.pumpAndSettle();
    await tapChannel(tester, 'T1/C3');
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(hub, account: 'discord/301'));
    await tester.pumpAndSettle();
    await expand(tester, 'Atlas');
    await tapChannel(tester, 'g-atlas/c-a-general');
    await tester.pumpAndSettle();

    // Leave Settings and come back: fetched from the bridge again.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    hub.calls.clear();
    await tester.pumpWidget(app(hub, account: 'slack/T1-U1'));
    await tester.pumpAndSettle();
    expect(hub.calls, [('GET', '/bridges/slack/provision/switchboard/v1/channels?login_id=T1-U1')]);
    expect(channelSwitch(tester, 'T1/C3').value, isTrue);
    expect(channelSwitch(tester, 'T1/C1').value, isFalse);
    await tester.pumpWidget(app(hub, account: 'discord/301'));
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'g-atlas/c-a-general').value, isTrue, reason: 'open, as it has a channel on');
    expect(hub.selected['slack/T2-U9'], {'C1'}, reason: "the other account's selection is untouched");

    // A relaunch starts with nothing in memory: a new provider scope.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: app(hub, account: 'slack/T1-U1')));
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'T1/C3').value, isTrue);
    await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: app(hub, account: 'discord/301')));
    await tester.pumpAndSettle();
    expect(channelSwitch(tester, 'g-atlas/c-a-general').value, isTrue);
  });

  testWidgets('loading, empty and failed lists each say what is happening', (tester) async {
    final hub = FakeBridges();
    final loading = Completer<void>();
    hub.scripted['/discord/provision/switchboard/v1/channels'] = loading;
    hub.scripted['/slack/provision/switchboard/v1/channels'] = (502, '{"errcode":"M_UNKNOWN","error":"ratelimited"}');
    hub.groups['discord/301'] = [];
    await tester.pumpWidget(app(hub, account: 'discord/301'));
    await settle(tester);
    expect(find.text('Loading channels…'), findsOneWidget);

    // Discord answers: the account is in no server with channels to show.
    loading.complete();
    hub.scripted.remove('/discord/provision/switchboard/v1/channels');
    await tester.pumpAndSettle();
    expect(find.text('Loading channels…'), findsNothing);
    expect(find.textContaining('No channels yet. Text channels this account can see'), findsOneWidget);

    await tester.pumpWidget(app(hub, account: 'slack/T1-U1'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load channels: ratelimited"), findsOneWidget);

    // Slack recovers; trying again fetches the list.
    hub.scripted.clear();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load channels: ratelimited"), findsNothing);
    expect(find.byKey(const ValueKey('T1/C1')), findsOneWidget);
  });

  testWidgets('a bridge from before channel selection says the server needs updating', (tester) async {
    final hub = FakeBridges();
    hub.scripted['/discord/provision/switchboard/v1/channels'] = (404, '404 page not found');
    await tester.pumpWidget(app(hub, bridges: [discord], account: 'discord/301'));
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

  for (final (name, screen) in <(String, Widget)>[
    ('the account list', ChannelsScreen()),
    ("an account's page", AccountChannelsScreen(bridgeId: 'slack', loginId: 'T1-U1')),
  ]) {
    testWidgets('while accounts load $name shows progress, and a failure offers to try again', (tester) async {
      final accounts = Completer<List<Bridge>>();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          hubProvider.overrideWithValue(HubApi(FakeBridges().send)),
          bridgesProvider.overrideWith((ref) => accounts.future),
        ],
        child: MaterialApp(home: screen),
      ));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      accounts.completeError(HubException('the Hub is unreachable'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't load accounts: the Hub is unreachable"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  }
}
