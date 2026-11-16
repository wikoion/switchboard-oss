import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:switchboard/src/rust/api/client.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/hub.dart';
import 'package:switchboard/src/state/rooms.dart';
import 'package:switchboard/src/state/session.dart';
import 'package:switchboard/src/state/views.dart';
import 'package:switchboard/src/ui/home_shell.dart';

const wa = Network(id: 'whatsapp', name: 'WhatsApp');

RoomSummary room(String name, {bool low = false, int notifying = 0, int messages = 0, int mentions = 0}) => RoomSummary(
      id: '!${name.toLowerCase()}',
      name: name,
      network: wa,
      isDm: true,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: false,
      isLowPriority: low,
      isMarkedUnread: false,
      preview: const Preview(isOwn: false, text: 'hi', sending: false, failed: false, isMembership: false),
      timestampMs: 10,
      unreadCount: notifying,
      mentionCount: mentions,
      unreadMessages: messages,
    );

/// Records what the app asks the core to do.
class FakeCore implements SwitchboardCore {
  final calls = <String>[];
  @override
  Future<void> setLowPriority({required List<String> roomIds, required bool lowPriority}) async =>
      calls.add('setLowPriority $roomIds $lowPriority');
  @override
  Future<void> markRoomsRead({required List<String> roomIds}) async => calls.add('markRoomsRead $roomIds');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final rooms = [
  room('Alice', notifying: 2, messages: 2),
  room('Promo', low: true, messages: 3),
  room('Club', low: true, notifying: 1, messages: 4, mentions: 1),
];

Future<FakeCore> pumpPhone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final core = FakeCore();
  final router = GoRouter(routes: [
    ShellRoute(
      builder: (_, s, child) => HomeShell(location: s.uri, child: child),
      routes: [GoRoute(path: '/', builder: (_, _) => const InboxHome())],
    ),
  ]);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      coreProvider.overrideWithValue(core),
      inboxProvider.overrideWithValue(rooms),
      viewsProvider.overrideWithValue(const [AllChats(), LowPriorityChats(), ArchivedChats()]),
      bridgesProvider.overrideWith((ref) async => const <Bridge>[]),
      syncStatusProvider.overrideWith((ref) => const Stream.empty()),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return core;
}

void select(WidgetTester tester, InboxView view) =>
    ProviderScope.containerOf(tester.element(find.byType(InboxHome))).read(selectedViewProvider.notifier).select(view);

void main() {
  test('Low Priority chats only appear in their own view', () {
    final low = room('Promo', low: true);
    for (final v in [const AllChats(), const FavouriteChats(), const NotesChats(), const NetworkChats(wa)]) {
      expect(inView(low, v), isFalse, reason: v.title);
    }
    expect(inView(low, const LowPriorityChats()), isTrue);
    expect(inView(room('Alice'), const LowPriorityChats()), isFalse);
    expect(inView(low, const LowPriorityChats(), archived: true), isFalse, reason: 'archived goes to the Archive');
  });

  test('their silent messages look unread but count for nothing', () {
    expect(looksUnread(rooms[1]), isTrue);
    expect(isUnread(rooms[1]), isFalse, reason: 'no badge, no notification');
    expect(isUnread(rooms[2]), isTrue, reason: 'a mention still counts');
  });

  testWidgets('the inbox leaves them out; the Low Priority view lists them, quietly', (tester) async {
    await pumpPhone(tester);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Promo'), findsNothing);
    expect(find.text('Club'), findsNothing);

    select(tester, const LowPriorityChats());
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsNothing);
    expect(find.text('Promo'), findsOneWidget);
    expect(find.text('3'), findsOneWidget, reason: 'its unread messages, in grey');
    expect(find.text('@'), findsOneWidget, reason: 'a mention shows as usual');
  });

  testWidgets('press and hold moves a chat to Low Priority and back', (tester) async {
    final core = await pumpPhone(tester);
    await tester.longPress(find.text('Alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to Low Priority'));
    await tester.pumpAndSettle();

    select(tester, const LowPriorityChats());
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Promo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from Low Priority'));
    await tester.pumpAndSettle();
    expect(core.calls, ['setLowPriority [!alice] true', 'setLowPriority [!promo] false']);
  });

  testWidgets('select mode moves several at once', (tester) async {
    final core = await pumpPhone(tester);
    select(tester, const LowPriorityChats());
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Promo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove from Low Priority'));
    await tester.pumpAndSettle();
    expect(core.calls, ['setLowPriority [!promo, !club] false']);
  });

  testWidgets('Mark all as read clears the grey counts too', (tester) async {
    final core = await pumpPhone(tester);
    select(tester, const LowPriorityChats());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark all as read'));
    await tester.pumpAndSettle();
    expect(core.calls, ['markRoomsRead [!promo, !club]']);
  });
}
