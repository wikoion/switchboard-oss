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

RoomSummary room(String name, {bool pinned = false, int unread = 0, int mentions = 0, bool marked = false}) =>
    RoomSummary(
      id: '!${name.toLowerCase().replaceAll(' ', '')}',
      name: name,
      network: wa,
      isDm: true,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: pinned,
      isLowPriority: false,
      isMarkedUnread: marked,
      timestampMs: 10,
      unreadCount: unread,
      mentionCount: mentions,
      unreadMessages: 0,
    );

Future<void> pumpInbox(WidgetTester tester, List<RoomSummary> rooms) async {
  tester.view.physicalSize = const Size(393, 852);
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

List<String> favourites(int n) =>
    ['Dora Sherborne', 'Wayne Cunningham', 'Doz', 'Lynn', 'Bunten', 'Jen', 'Christine', 'Tom', 'Sam'].take(n).toList();

/// Rows of favourites, top to bottom, each as the names' centres left to right.
List<List<Offset>> layout(WidgetTester tester, List<String> names) {
  final centres = [for (final n in names) tester.getCenter(find.text(n))];
  final rows = <double, List<Offset>>{};
  for (final c in centres) {
    (rows[c.dy] ??= []).add(c);
  }
  return [
    for (final y in rows.keys.toList()..sort()) rows[y]!..sort((a, b) => a.dx.compareTo(b.dx)),
  ];
}

void main() {
  const width = 393.0;

  for (final (count, shape) in [
    (1, [1]),
    (2, [2]),
    (3, [3]),
    (4, [4]),
    (5, [3, 2]),
    (6, [3, 3]),
    (7, [4, 3]),
    (8, [4, 4]),
    (9, [3, 3, 3]),
  ]) {
    testWidgets('$count favourites sit in rows of $shape, evenly spaced and centred', (tester) async {
      final names = favourites(count);
      await pumpInbox(tester, [for (final n in names) room(n, pinned: true), room('Alice')]);
      final rows = layout(tester, names);
      expect([for (final r in rows) r.length], shape);
      for (final r in rows) {
        // Centred on the screen.
        expect((r.first.dx + r.last.dx) / 2, moreOrLessEquals(width / 2, epsilon: 1));
        // Even gaps, wide enough that the names never meet.
        for (var i = 1; i < r.length; i++) {
          expect(r[i].dx - r[i - 1].dx, moreOrLessEquals(r[1].dx - r[0].dx, epsilon: 1));
          expect(r[i].dx - r[i - 1].dx, greaterThanOrEqualTo(90));
        }
      }
      // Long names stop short of their neighbours.
      for (final r in [for (final n in names) tester.getRect(find.text(n))]) {
        for (final o in [for (final n in names) tester.getRect(find.text(n))]) {
          if (r != o) expect(r.overlaps(o), isFalse);
        }
      }
    });
  }

  testWidgets('favourites show their unread count on the avatar', (tester) async {
    await pumpInbox(tester, [
      room('Dora', pinned: true, unread: 3),
      room('Wayne', pinned: true, unread: 2, mentions: 1),
      room('Doz', pinned: true, marked: true),
      room('Lynn', pinned: true),
      room('Alice'),
    ]);
    // The count sits on the avatar's top-right corner, above the name.
    final dora = tester.getRect(find.text('Dora'));
    final three = tester.getRect(find.text('3'));
    expect(three.center.dx, greaterThan(dora.center.dx));
    expect(three.bottom, lessThan(dora.top));
    expect(find.text('@'), findsOneWidget, reason: 'mentions show @, as in the list');
    expect(tester.widget<Text>(find.text('Dora')).style!.fontWeight, FontWeight.w700);
    expect(tester.widget<Text>(find.text('Doz')).style!.fontWeight, FontWeight.w700, reason: 'marked unread');
    expect(tester.widget<Text>(find.text('Lynn')).style!.fontWeight, FontWeight.w500);
  });
}
