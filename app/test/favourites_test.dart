import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/client.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/favourites.dart';
import 'package:switchboard/src/state/rooms.dart';
import 'package:switchboard/src/state/session.dart';

RoomSummary room(String id, {bool favourite = false, double? order}) => RoomSummary(
      id: id,
      name: id,
      isDm: true,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: favourite,
      favouriteOrder: order,
      isLowPriority: false,
      isMarkedUnread: false,
      unreadCount: 0,
      unreadMessages: 0,
      mentionCount: 0,
    );

/// The server's side of favourites: it takes changes only while [online].
class FakeCore implements SwitchboardCore {
  bool online = false;
  final calls = <String>[];

  @override
  Future<void> setFavourite({required String roomId, required bool favourite, double? order}) async {
    if (!online) throw Exception('no connection');
    calls.add('$roomId ${favourite ? 'on $order' : 'off'}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ServerRooms extends RoomListNotifier {
  ServerRooms(this.rooms);
  final List<RoomSummary> rooms;

  @override
  List<RoomSummary>? build() => rooms;

  void put(List<RoomSummary> next) => state = next;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sb-favourites'));
  tearDown(() => dir.deleteSync(recursive: true));

  (ProviderContainer, FakeCore, ServerRooms, StreamController<SyncStatus>) start(List<RoomSummary> rooms) {
    final core = FakeCore();
    final server = ServerRooms(rooms);
    final sync = StreamController<SyncStatus>();
    final container = ProviderContainer(overrides: [
      coreProvider.overrideWithValue(core),
      serverRoomListProvider.overrideWith(() => server),
      syncStatusProvider.overrideWith((ref) => sync.stream),
      pendingFavouritesFileProvider.overrideWithValue(() async => File('${dir.path}/pending.json')),
    ]);
    addTearDown(container.dispose);
    addTearDown(sync.close);
    return (container, core, server, sync);
  }

  bool starred(ProviderContainer c, String id) => c.read(roomListProvider)!.firstWhere((r) => r.id == id).isFavourite;

  test('a favourite made with no connection shows at once and reaches the server later', () {
    fakeAsync((async) {
      final (container, core, server, sync) = start([room('!a'), room('!b')]);
      container.listen(roomListProvider, (_, _) {});
      container.read(pendingFavouritesProvider.notifier).set('!a', favourite: true, order: 0.5);
      async.flushMicrotasks();
      expect(starred(container, '!a'), isTrue);
      expect(starred(container, '!b'), isFalse);
      expect(core.calls, isEmpty);

      // Still out of reach a while later: it keeps showing.
      async.elapse(const Duration(minutes: 2));
      expect(starred(container, '!a'), isTrue);
      expect(core.calls, isEmpty);

      core.online = true;
      sync.add(SyncStatus.running);
      async.elapse(const Duration(seconds: 1));
      expect(core.calls, ['!a on 0.5']);
      expect(starred(container, '!a'), isTrue);

      // The chat list catches up, and nothing is left waiting.
      server.put([room('!a', favourite: true, order: 0.5), room('!b')]);
      async.flushMicrotasks();
      expect(container.read(pendingFavouritesProvider), isEmpty);
      expect(starred(container, '!a'), isTrue);
    });
  });

  test('a change that never got out is still there after a relaunch, and goes out then', () async {
    final (first, _, _, _) = start([room('!a', favourite: true, order: 0.5)]);
    first.listen(roomListProvider, (_, _) {});
    first.read(pendingFavouritesProvider.notifier).set('!a', favourite: false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(starred(first, '!a'), isFalse);
    first.dispose();

    final (second, core, _, _) = start([room('!a', favourite: true, order: 0.5)]);
    core.online = true;
    second.listen(roomListProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(starred(second, '!a'), isFalse);
    expect(core.calls, ['!a off']);
  });

  test('changing your mind sends only where it ended up', () {
    fakeAsync((async) {
      final (container, core, _, sync) = start([room('!a')]);
      container.listen(roomListProvider, (_, _) {});
      final pending = container.read(pendingFavouritesProvider.notifier);
      pending.set('!a', favourite: true, order: 0.5);
      pending.set('!a', favourite: false);
      async.flushMicrotasks();
      expect(starred(container, '!a'), isFalse);
      core.online = true;
      sync.add(SyncStatus.running);
      async.elapse(const Duration(seconds: 1));
      expect(core.calls, ['!a off']);
    });
  });
}
