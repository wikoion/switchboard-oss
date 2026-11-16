import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/diff.dart';
import 'package:switchboard/src/state/rooms.dart';

RoomSummary room(String id, {List<String> dm = const []}) => RoomSummary(
      id: id,
      name: id,
      isDm: true,
      dmUserIds: dm,
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: false,
      isLowPriority: false,
      isMarkedUnread: false,
      unreadCount: 0,
      mentionCount: 0,
      unreadMessages: 0,
    );

List<String> ids(List<RoomSummary> l) => [for (final r in l) r.id];

void main() {
  test('applies every VectorDiff kind in order', () {
    var list = applyRoomDiffs(const [], [
      RoomListDiff.reset(values: [room('a'), room('b')]),
      RoomListDiff.pushFront(value: room('z')),
      RoomListDiff.pushBack(value: room('c')),
      RoomListDiff.insert(index: 2, value: room('x')),
    ]);
    expect(ids(list), ['z', 'a', 'x', 'b', 'c']);

    list = applyRoomDiffs(list, [
      RoomListDiff.set_(index: 1, value: room('A')),
      RoomListDiff.remove(index: 2),
      RoomListDiff.popFront(),
      RoomListDiff.popBack(),
    ]);
    expect(ids(list), ['A', 'b']);

    list = applyRoomDiffs(list, [
      RoomListDiff.append(values: [room('d'), room('e')]),
      RoomListDiff.truncate(length: 3),
    ]);
    expect(ids(list), ['A', 'b', 'd']);

    expect(applyRoomDiffs(list, [const RoomListDiff.clear()]), isEmpty);
  });

  test('does not mutate the previous list', () {
    final before = [room('a')];
    applyRoomDiffs(before, [RoomListDiff.pushBack(value: room('b'))]);
    expect(ids(before), ['a']);
  });

  test('bridge bot chats are recognised', () {
    const bots = {'@whatsappbot:switchboard.internal', '@signalbot:switchboard.internal'};
    expect(isBotChat(room('a', dm: ['@whatsappbot:switchboard.internal']), bots), isTrue);
    expect(isBotChat(room('b', dm: ['@whatsapp_447700900123:switchboard.internal']), bots), isFalse);
    expect(isBotChat(room('c'), bots), isFalse);
  });
}
