import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/rooms.dart';

RoomSummary room(String id, int? sentMs, {bool join = false}) => RoomSummary(
      id: id,
      name: id,
      isDm: true,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: false,
      isLowPriority: false,
      isMarkedUnread: false,
      preview: join ? const Preview(isOwn: true, text: 'Rich joined', sending: false, failed: false, isMembership: true) : null,
      timestampMs: sentMs,
      unreadCount: 0,
      mentionCount: 0,
      unreadMessages: 0,
    );

void main() {
  test('chats sort by when their newest message was sent, not by server activity', () {
    // The SDK's order: two chats a network linked a minute ago come first,
    // though their newest messages are weeks old.
    final sdkOrder = [
      room('!linked-old', 1000),
      room('!linked-older', 500),
      room('!empty', null),
      room('!today', 9000),
      room('!yesterday', 5000),
      room('!tie-a', 3000),
      room('!tie-b', 3000),
    ];
    expect(byNewestMessage(sdkOrder).map((r) => r.id), [
      '!today',
      '!yesterday',
      '!tie-a',
      '!tie-b',
      '!linked-old',
      '!linked-older',
      '!empty',
    ]);
  });

  test('a chat whose latest event is your join sorts with the empty chats', () {
    final sdkOrder = [room('!joined-today', 9000, join: true), room('!last-year', 100), room('!empty', null)];
    expect(byNewestMessage(sdkOrder).map((r) => r.id), ['!last-year', '!joined-today', '!empty']);
  });
}
