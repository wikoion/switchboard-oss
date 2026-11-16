import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/notify.dart';

const wa = Network(id: 'whatsapp', name: 'WhatsApp');

final now = DateTime(2026, 11, 1, 12);

RoomSummary room(String id, int unread,
        {bool dm = true, String? sender, bool own = false, String text = 'hi', Duration ago = Duration.zero}) =>
    RoomSummary(
      id: id,
      name: id == '!family' ? 'Family' : 'Alice',
      network: wa,
      isDm: dm,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: false,
      isLowPriority: false,
      isMarkedUnread: false,
      preview: Preview(senderName: sender, isOwn: own, text: text, sending: false, failed: false, isMembership: false),
      timestampMs: now.subtract(ago).millisecondsSinceEpoch,
      unreadCount: unread,
      mentionCount: 0,
      unreadMessages: 0,
    );

void main() {
  test('only chats whose count rose notify, not the open one or your own messages', () {
    final before = {'!a': 1, '!b': 2, '!open': 0};
    final rooms = [
      room('!a', 2),
      room('!b', 2),
      room('!open', 3),
      room('!new', 1),
      room('!quiet', 0),
      room('!mine', 1, own: true),
    ];
    expect(newlyNotifying(before, rooms, openRoomId: '!open', now: now).map((r) => r.id), ['!a', '!new']);
  });

  test('chats a new network brings in only notify for recent messages', () {
    final rooms = [
      room('!history', 5, ago: const Duration(days: 3)),
      room('!justnow', 1, ago: const Duration(seconds: 20)),
      room('!known', 3, ago: const Duration(hours: 6)),
    ];
    expect(
      newlyNotifying({'!known': 1}, rooms, now: now).map((r) => r.id),
      ['!justnow', '!known'],
      reason: 'old messages in a chat already listed still notify: they were missed, not imported',
    );
  });

  test('a read chat going back to zero does not notify', () {
    expect(newlyNotifying({'!a': 4}, [room('!a', 0)], now: now), isEmpty);
  });

  test('text names the sender in groups and the network', () {
    expect(notificationText(room('!a', 1, text: 'See you at 7')), (title: 'Alice · WhatsApp', body: 'See you at 7'));
    expect(
      notificationText(room('!family', 1, dm: false, sender: 'Mum', text: 'Photo')),
      (title: 'Mum in Family · WhatsApp', body: 'Photo'),
    );
  });

  test('notification IDs are stable per chat and never 0', () {
    expect(notificationId('!a:x'), notificationId('!a:x'));
    expect(notificationId('!a:x'), isNot(0));
  });
}
