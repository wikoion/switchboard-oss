import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/notify.dart';

const wa = Network(id: 'whatsapp', name: 'WhatsApp');

final now = DateTime(2026, 11, 1, 12);

RoomSummary room(String id, int unread,
        {bool dm = true,
        String? sender,
        bool own = false,
        String text = 'hi',
        Duration ago = Duration.zero,
        String? picture,
        String? senderPicture,
        bool membership = false}) =>
    RoomSummary(
      id: id,
      name: id == '!family' ? 'Family' : 'Alice',
      avatarMxc: picture,
      network: wa,
      isDm: dm,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: false,
      isLowPriority: false,
      isMarkedUnread: false,
      preview: Preview(
        senderName: sender,
        senderAvatarMxc: senderPicture,
        isOwn: own,
        text: text,
        sending: false,
        failed: false,
        isMembership: membership,
      ),
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

  test('hiding the sender names neither them nor the chat', () {
    expect(
      notificationText(room('!a', 1, text: 'See you at 7'), hideSender: true),
      (title: 'New message · WhatsApp', body: 'See you at 7'),
    );
    final group = notificationText(room('!family', 1, dm: false, sender: 'Mum', text: 'Photo'), hideSender: true);
    expect(group, (title: 'New message · WhatsApp', body: 'Photo'));
    // A join is worded around the member's name.
    final joined = room('!family', 1, dm: false, sender: 'Mum', text: 'Mum joined', membership: true);
    expect(notificationText(joined, hideSender: true), (title: 'New message · WhatsApp', body: 'New message'));
    expect(notificationText(joined).body, 'Mum joined');
  });

  test("the picture is the sender's own, or a direct chat's, never a group's", () {
    const alice = 'mxc://example.org/alice';
    const chat = 'mxc://example.org/chat';
    expect(senderPicture(room('!a', 1, picture: chat, senderPicture: alice)), alice);
    expect(senderPicture(room('!a', 1, picture: chat)), chat, reason: "a direct chat's picture is the other person's");
    expect(senderPicture(room('!family', 1, dm: false, sender: 'Mum', picture: chat, senderPicture: alice)), alice);
    expect(senderPicture(room('!family', 1, dm: false, sender: 'Mum', picture: chat)), isNull);
    expect(senderPicture(room('!a', 1)), isNull);
    expect(senderPicture(room('!a', 1, senderPicture: 'https://example.org/a.png')), isNull);
  });

  test('notification IDs are stable per chat and never 0', () {
    expect(notificationId('!a:x'), notificationId('!a:x'));
    expect(notificationId('!a:x'), isNot(0));
  });
}
