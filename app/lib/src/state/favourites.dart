// Favourites changed on this device. A change shows at once and is kept in
// a file until the server has it, so favouriting works with no connection
// and survives the app closing before it could be sent.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../rust/api/types.dart';
import 'rooms.dart';
import 'session.dart';

/// One chat's change: in the favourites at [order], or out of them.
class PendingFavourite {
  const PendingFavourite({required this.favourite, this.order, this.sent = false});

  final bool favourite;
  final double? order;

  /// The server took it; it stays until the chat list says the same, so
  /// the star doesn't flick back in between.
  final bool sent;

  PendingFavourite asSent() => PendingFavourite(favourite: favourite, order: order, sent: true);

  bool matches(RoomSummary room) => room.isFavourite == favourite && (!favourite || room.favouriteOrder == order);

  Map<String, dynamic> toJson() => {'favourite': favourite, 'order': ?order};

  static PendingFavourite? fromJson(Object? j) =>
      j is Map && j['favourite'] is bool
          ? PendingFavourite(favourite: j['favourite'] as bool, order: (j['order'] as num?)?.toDouble())
          : null;
}

/// The file the changes wait in.
final pendingFavouritesFileProvider = Provider<Future<File> Function()>(
  (ref) => () async => File('${(await getApplicationSupportDirectory()).path}/pending_favourites.json'),
);

/// How long a change the server took may wait for the chat list to agree.
const _confirmWithin = Duration(seconds: 30);

/// Favourite changes the server doesn't have yet, by chat.
final pendingFavouritesProvider =
    NotifierProvider<PendingFavourites, Map<String, PendingFavourite>>(PendingFavourites.new);

class PendingFavourites extends Notifier<Map<String, PendingFavourite>> {
  Timer? _retry;
  int _failures = 0;
  bool _sending = false;

  @override
  Map<String, PendingFavourite> build() {
    ref.watch(coreProvider);
    ref.onDispose(() => _retry?.cancel());
    // Changes left from the last run go out once the server is in reach.
    unawaited(_load());
    ref.listen(syncStatusProvider, (_, next) {
      if (next.value == SyncStatus.running) unawaited(_send());
    });
    // A change is done with once the chat list has it.
    ref.listen(serverRoomListProvider, (_, rooms) {
      if (rooms == null || state.isEmpty) return;
      final byId = {for (final r in rooms) r.id: r};
      final left = {
        for (final MapEntry(key: id, value: change) in state.entries)
          if (!(change.sent && (byId[id]?.let(change.matches) ?? false))) id: change,
      };
      if (left.length != state.length) _set(left);
    });
    return const {};
  }

  /// Adds [roomId] to the favourites at [order], or takes it out. Shows at
  /// once; the server gets it now or when it can next be reached.
  void set(String roomId, {required bool favourite, double? order}) {
    _set({...state, roomId: PendingFavourite(favourite: favourite, order: favourite ? order : null)});
    _failures = 0;
    unawaited(_send());
  }

  void _set(Map<String, PendingFavourite> next) {
    state = next;
    unawaited(_save());
  }

  Future<void> _load() async {
    try {
      final file = await ref.read(pendingFavouritesFileProvider)();
      if (!await file.exists()) return;
      final saved = jsonDecode(await file.readAsString());
      if (saved is! Map || !ref.mounted) return;
      // Anything changed since launch wins over what was saved.
      final loaded = <String, PendingFavourite>{};
      for (final MapEntry(:key, :value) in saved.entries) {
        final change = PendingFavourite.fromJson(value);
        if (key is String && change != null) loaded[key] = change;
      }
      state = {...loaded, ...state};
      unawaited(_send());
    } catch (_) {
      // Nothing saved that can be read.
    }
  }

  Future<void> _save() async {
    try {
      final file = await ref.read(pendingFavouritesFileProvider)();
      final unsent = {
        for (final MapEntry(key: id, value: change) in state.entries)
          if (!change.sent) id: change.toJson(),
      };
      if (unsent.isEmpty) {
        if (await file.exists()) await file.delete();
      } else {
        await file.create(recursive: true);
        await file.writeAsString(jsonEncode(unsent));
      }
    } catch (_) {
      // Kept in memory for this run.
    }
  }

  Future<void> _send() async {
    if (_sending) return;
    _sending = true;
    _retry?.cancel();
    var failed = false;
    try {
      final core = ref.read(coreProvider);
      for (final MapEntry(key: id, value: change) in state.entries.toList()) {
        if (change.sent) continue;
        try {
          await core.setFavourite(roomId: id, favourite: change.favourite, order: change.order);
        } catch (_) {
          failed = true;
          continue;
        }
        if (!ref.mounted) return;
        // Changed again while this one was on its way: that one goes next.
        if (!identical(state[id], change)) {
          failed = true;
          continue;
        }
        _set({...state, id: change.asSent()});
        Timer(_confirmWithin, () {
          if (ref.mounted && (state[id]?.sent ?? false)) _set({...state}..remove(id));
        });
      }
    } catch (_) {
      // Not signed in.
      failed = true;
    } finally {
      _sending = false;
    }
    if (!ref.mounted) return;
    if (!failed) {
      // One made while those were on their way.
      if (state.values.any((c) => !c.sent)) unawaited(_send());
      return;
    }
    // No connection, most likely: try again, less and less often, and
    // whenever sync comes back.
    _failures++;
    _retry = Timer(Duration(seconds: 2 << _failures.clamp(0, 5)), () => unawaited(_send()));
  }
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// [room] as a change waiting for the server would have it.
RoomSummary withFavourite(RoomSummary room, PendingFavourite change) => RoomSummary(
      id: room.id,
      name: room.name,
      avatarMxc: room.avatarMxc,
      network: room.network,
      isDm: room.isDm,
      dmUserIds: room.dmUserIds,
      memberCount: room.memberCount,
      heroUserIds: room.heroUserIds,
      isInvite: room.isInvite,
      isFavourite: change.favourite,
      favouriteOrder: change.favourite ? change.order : null,
      isLowPriority: room.isLowPriority,
      isMarkedUnread: room.isMarkedUnread,
      archivedAt: room.archivedAt,
      preview: room.preview,
      timestampMs: room.timestampMs,
      unreadCount: room.unreadCount,
      unreadMessages: room.unreadMessages,
      mentionCount: room.mentionCount,
    );
