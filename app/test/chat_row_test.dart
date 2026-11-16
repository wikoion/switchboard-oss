import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/ui/chat_list_screen.dart';
import 'package:switchboard/src/ui/theme.dart';

final now = DateTime.now().millisecondsSinceEpoch;
const wa = Network(id: 'whatsapp', name: 'WhatsApp');
const sig = Network(id: 'signal', name: 'Signal');

RoomSummary row(
  String name, {
  Network? network,
  bool dm = true,
  Preview? preview,
  int unread = 0,
  int mentions = 0,
  bool markedUnread = false,
  bool invite = false,
}) =>
    RoomSummary(
      id: '!$name:x',
      name: name,
      network: network,
      isDm: dm,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: invite,
      isFavourite: false,
      isLowPriority: false,
      isMarkedUnread: markedUnread,
      preview: preview,
      timestampMs: now,
      unreadCount: unread,
      mentionCount: mentions,
      unreadMessages: 0,
    );

Preview said(String text, {String? sender, bool own = false, bool failed = false}) =>
    Preview(senderName: sender, isOwn: own, text: text, sending: false, failed: failed, isMembership: false);

/// Every row state the spec lists, top to bottom.
final rows = [
  row('Alice', network: wa, preview: said('See you at 7'), unread: 3),
  row('Family', network: wa, dm: false, preview: said('Photo', sender: 'Mum'), unread: 12, mentions: 1),
  row('Bob', network: sig, preview: said('On my way', own: true)),
  row('Carol', network: sig, preview: said('Did it send?', own: true, failed: true)),
  row('Dave', preview: said('Marked for later'), markedUnread: true),
  row('New group', network: wa, dm: false, invite: true),
];

Widget list() => ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: ListView(children: [for (final r in rows) ChatRow(room: r)])),
      ),
    );

void main() {
  testWidgets('row states show the right preview, counts and markers', (tester) async {
    await tester.pumpWidget(list());
    await tester.pump();

    expect(find.text('See you at 7'), findsOneWidget, reason: 'DMs have no sender prefix');
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Mum: Photo'), findsOneWidget, reason: 'groups name the sender');
    expect(find.text('@'), findsOneWidget, reason: 'a mention shows @ instead of the count');
    expect(find.text('You: On my way'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget, reason: 'failed send');
    expect(find.text('Invited you'), findsOneWidget);
  });

  testWidgets('chat list golden', (tester) async {
    tester.view.physicalSize = const Size(1179, 1300);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(list());
    await tester.pump();
    await expectLater(find.byType(ListView), matchesGoldenFile('goldens/chat_list.png'));
  });
}
