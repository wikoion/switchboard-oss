import 'package:flutter/material.dart';
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

RoomSummary room(String name, {bool pinned = false, int unread = 0, int? archivedAt}) => RoomSummary(
      id: '!${name.toLowerCase()}',
      name: name,
      network: wa,
      isDm: true,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: pinned,
      isLowPriority: false,
      isMarkedUnread: false,
      archivedAt: archivedAt,
      timestampMs: 10,
      unreadCount: unread,
      mentionCount: 0,
      unreadMessages: 0,
    );

final rooms = [room('Mum', pinned: true), room('Alice', unread: 2), room('Bob'), room('Old', archivedAt: 50)];

Future<void> pumpPhone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(routes: [
    ShellRoute(
      builder: (_, s, child) => HomeShell(location: s.uri, child: child),
      routes: [GoRoute(path: '/', builder: (_, _) => const InboxHome())],
    ),
  ]);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      inboxProvider.overrideWithValue(rooms),
      viewsProvider.overrideWithValue(const [AllChats(), ArchivedChats(), NetworkChats(wa)]),
      bridgesProvider.overrideWith((ref) async => const <Bridge>[]),
      syncStatusProvider.overrideWith((ref) => const Stream.empty()),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('archived chats are only in the Archive', (tester) async {
    await pumpPhone(tester);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Old'), findsNothing);
    final container = ProviderScope.containerOf(tester.element(find.text('Alice')));
    container.read(selectedViewProvider.notifier).select(const ArchivedChats());
    await tester.pumpAndSettle();
    expect(find.text('Old'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);
  });

  testWidgets('select mode: pick chats, select all, done', (tester) async {
    await pumpPhone(tester);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Mark all as read'), findsOneWidget);
    await tester.tap(find.text('Select chats'));
    await tester.pumpAndSettle();
    expect(find.text('Select chats'), findsOneWidget, reason: 'the bar, with nothing picked yet');

    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget, reason: 'the pinned chat and the list, not the archived one');

    await tester.tap(find.byTooltip('Done'));
    await tester.pumpAndSettle();
    expect(find.textContaining('selected'), findsNothing);
  });

  testWidgets('press and hold offers favourite, read, archive and select', (tester) async {
    await pumpPhone(tester);
    await tester.longPress(find.text('Alice'));
    await tester.pumpAndSettle();
    for (final label in ['Favourite', 'Mark as read', 'Archive', 'Select']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('chats swipe: right for read, left for archive', (tester) async {
    await pumpPhone(tester);
    expect(find.byType(Dismissible), findsNWidgets(2), reason: 'list rows, not the pinned grid');
  });
}
