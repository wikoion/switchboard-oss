import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/hub.dart';
import 'package:switchboard/src/state/rooms.dart';
import 'package:switchboard/src/ui/forward.dart';

const wa = Network(id: 'whatsapp', name: 'WhatsApp');
const sig = Network(id: 'signal', name: 'Signal');

RoomSummary room(String name, Network network, {bool invite = false}) => RoomSummary(
      id: '!${name.toLowerCase()}',
      name: name,
      network: network,
      isDm: true,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: invite,
      isFavourite: false,
      isLowPriority: false,
      isMarkedUnread: false,
      unreadCount: 0,
      mentionCount: 0,
      unreadMessages: 0,
    );

void main() {
  testWidgets('lists the chats without invites, searches them and returns the one tapped', (tester) async {
    RoomSummary? picked;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        inboxProvider.overrideWithValue([room('Alice', wa), room('Bob', sig), room('Stranger', sig, invite: true)]),
        bridgesProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await showModalBottomSheet<RoomSummary>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const ForwardPicker(),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Stranger'), findsNothing);

    await tester.enterText(find.byType(TextField), 'bo');
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsNothing);

    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    expect(picked?.id, '!bob');
  });
}
