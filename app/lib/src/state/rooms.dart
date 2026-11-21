import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import 'diff.dart';
import 'favourites.dart';
import 'hub.dart';
import 'session.dart';

/// The chat list as the server has it, newest first. Null until the first
/// update arrives.
final serverRoomListProvider =
    NotifierProvider<RoomListNotifier, List<RoomSummary>?>(RoomListNotifier.new);

/// The chat list, with the favourites changed on this device that the
/// server doesn't have yet.
final roomListProvider = Provider<List<RoomSummary>?>((ref) {
  final rooms = ref.watch(serverRoomListProvider);
  final pending = ref.watch(pendingFavouritesProvider);
  if (rooms == null || pending.isEmpty) return rooms;
  return [
    for (final r in rooms)
      if (pending[r.id] case final change?) withFavourite(r, change) else r,
  ];
});

class RoomListNotifier extends Notifier<List<RoomSummary>?> {
  @override
  List<RoomSummary>? build() {
    final core = ref.watch(coreProvider);
    final sub = core.subscribeRoomList().listen((diffs) {
      state = applyRoomDiffs(state ?? const [], diffs);
    });
    ref.onDispose(sub.cancel);
    return null;
  }
}

/// One room's summary, from the list.
final roomSummaryProvider = Provider.family<RoomSummary?, String>((ref, roomId) {
  final rooms = ref.watch(roomListProvider);
  if (rooms == null) return null;
  for (final r in rooms) {
    if (r.id == roomId) return r;
  }
  return null;
});

/// The bridge bots' user IDs, from the Hub. Empty until it answers.
final bridgeBotsProvider = Provider<Set<String>>((ref) {
  final bridges = ref.watch(bridgesProvider).value ?? const [];
  return {for (final b in bridges) ?b.botUserId};
});

/// Chats the server deleted, which this device still had: checked once a
/// session, dropped from the local store, and hidden until next launch.
final staleRoomsProvider = FutureProvider<Set<String>>((ref) async {
  try {
    return (await ref.watch(coreProvider).forgetStaleRooms()).toSet();
  } catch (_) {
    return const {};
  }
});

/// The inbox: the chat list without the bridge bots' management chats
/// and without chats the server has deleted.
final inboxProvider = Provider<List<RoomSummary>?>((ref) {
  final rooms = ref.watch(roomListProvider);
  final bots = ref.watch(bridgeBotsProvider);
  final stale = ref.watch(staleRoomsProvider).value ?? const {};
  if (rooms == null) return null;
  return byNewestMessage([for (final r in rooms) if (!isBotChat(r, bots) && !stale.contains(r.id)) r]);
});

/// Newest message first, by when it was sent. The SDK orders chats by
/// server activity, which a chat's creation and the history a bridge
/// imports also count as, so a newly linked network's chats would sit on
/// top whatever their age. Chats without messages go last, and so do
/// chats whose latest event is your join; ties keep the SDK's order.
List<RoomSummary> byNewestMessage(List<RoomSummary> rooms) {
  int sent(RoomSummary r) => (r.preview?.isMembership ?? false) ? 0 : r.timestampMs ?? 0;
  final indexed = rooms.indexed.toList()
    ..sort((a, b) {
      final byTime = sent(b.$2).compareTo(sent(a.$2));
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  return [for (final (_, r) in indexed) r];
}

bool isBotChat(RoomSummary room, Set<String> bots) =>
    room.isDm && room.dmUserIds.isNotEmpty && room.dmUserIds.every(bots.contains);
