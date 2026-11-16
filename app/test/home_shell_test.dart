import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/hub.dart';
import 'package:switchboard/src/state/rooms.dart';
import 'package:switchboard/src/state/session.dart';
import 'package:switchboard/src/state/views.dart';
import 'package:switchboard/src/ui/home_shell.dart';

const wa = Network(id: 'whatsapp', name: 'WhatsApp');
const sig = Network(id: 'signal', name: 'Signal');

RoomSummary room(String name, Network network, {bool pinned = false, int unread = 0}) => RoomSummary(
      id: '!${name.toLowerCase()}',
      name: name,
      network: network,
      isDm: true,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: pinned,
      isLowPriority: false,
      isMarkedUnread: false,
      unreadCount: unread,
      mentionCount: 0,
      unreadMessages: 0,
    );

final rooms = [
  room('Mum', wa, pinned: true),
  room('Alice', wa, unread: 2),
  room('Bob', sig),
  room('Tom', sig, unread: 1),
];

/// The inbox routes as the app has them, with stand-in pages.
Future<void> pumpApp(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(routes: [
    ShellRoute(
      builder: (_, s, child) => HomeShell(location: s.uri, child: child),
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const InboxHome(),
          routes: [
            GoRoute(path: 'room/:id', builder: (_, s) => Scaffold(body: Text('chat ${s.pathParameters['id']}'))),
            GoRoute(path: 'settings', builder: (_, _) => const Scaffold(body: Text('settings page'))),
          ],
        ),
      ],
    ),
  ]);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      inboxProvider.overrideWithValue(rooms),
      viewsProvider.overrideWithValue(const [AllChats(), NetworkChats(sig), NetworkChats(wa)]),
      bridgesProvider.overrideWith((ref) async => [
            Bridge(
              id: 'whatsapp',
              network: 'WhatsApp',
              reachable: true,
              supportsApi: true,
              networkId: 'whatsapp',
              logins: [BridgeLogin(id: '1', name: 'Me', state: 'BAD_CREDENTIALS')],
            ),
          ]),
      syncStatusProvider.overrideWith((ref) => const Stream.empty()),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {bool alt = false, bool ctrl = false, bool shift = false}) async {
  final mods = [
    if (alt) LogicalKeyboardKey.altLeft,
    if (ctrl) LogicalKeyboardKey.controlLeft,
    if (shift) LogicalKeyboardKey.shiftLeft,
  ];
  for (final m in mods) {
    await tester.sendKeyDownEvent(m);
  }
  await tester.sendKeyEvent(key);
  for (final m in mods.reversed) {
    await tester.sendKeyUpEvent(m);
  }
  await tester.pumpAndSettle();
}

final linux = TargetPlatformVariant.only(TargetPlatform.linux);

void main() {
  testWidgets('900 px and wider: sidebar, list and the open chat side by side', variant: linux, (tester) async {
    await pumpApp(tester, const Size(1280, 800));

    expect(find.text('Pick a chat'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget, reason: 'sidebar');
    expect(find.text('Signal'), findsOneWidget, reason: 'sidebar view');
    expect(find.byTooltip('Needs attention'), findsOneWidget, reason: 'WhatsApp login needs relinking');

    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    expect(find.text('chat !alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget, reason: 'the list stays beside the chat');

    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    expect(find.text('chat !bob'), findsOneWidget);
    expect(find.text('chat !alice'), findsNothing, reason: 'the open chat is replaced, not stacked');
  });

  testWidgets('keyboard: Alt+arrows, next unread, pinned chats, jump bar, settings', variant: linux, (tester) async {
    await pumpApp(tester, const Size(1280, 800));

    // List order: pinned Mum, then Alice, Bob, Tom.
    await press(tester, LogicalKeyboardKey.arrowDown, alt: true);
    expect(find.text('chat !mum'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.arrowDown, alt: true);
    expect(find.text('chat !alice'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.arrowDown, alt: true, shift: true);
    expect(find.text('chat !tom'), findsOneWidget, reason: 'next unread below Alice');
    await press(tester, LogicalKeyboardKey.arrowUp, alt: true);
    expect(find.text('chat !bob'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.digit1, ctrl: true);
    expect(find.text('chat !mum'), findsOneWidget, reason: 'first pinned chat');

    await press(tester, LogicalKeyboardKey.keyK, ctrl: true);
    expect(find.text('Jump to chat'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'to');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('chat !tom'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.comma, ctrl: true);
    expect(find.text('settings page'), findsOneWidget);
  });

  testWidgets('600 to 900 px: list and chat, no sidebar', variant: linux, (tester) async {
    await pumpApp(tester, const Size(760, 800));
    expect(find.text('Pick a chat'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('under 600 px: the phone layout, where a chat covers the list', variant: linux, (tester) async {
    await pumpApp(tester, const Size(480, 800));
    expect(find.text('Pick a chat'), findsNothing);
    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    expect(find.text('chat !alice'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);
  });
}
