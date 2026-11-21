// Inbox views: everything, one network, or one linked account.

import 'favourites.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import 'hub.dart';
import 'rooms.dart';
import 'session.dart';

sealed class InboxView {
  const InboxView();
  String get title;
}

class AllChats extends InboxView {
  const AllChats();
  @override
  String get title => 'Inbox';
  @override
  bool operator ==(Object other) => other is AllChats;
  @override
  int get hashCode => 0;
}

/// Favourite chats, in the order you put them. The inbox
/// shows them as the grid on top; this view lists them for reordering.
class FavouriteChats extends InboxView {
  const FavouriteChats();
  @override
  String get title => 'Favourites';
  @override
  bool operator ==(Object other) => other is FavouriteChats;
  @override
  int get hashCode => 2;
}

/// Archived chats: out of the inbox until someone writes.
class ArchivedChats extends InboxView {
  const ArchivedChats();
  @override
  String get title => 'Archive';
  @override
  bool operator ==(Object other) => other is ArchivedChats;
  @override
  int get hashCode => 3;
}

/// Low Priority: chats you've moved out of the inbox. They
/// only notify when someone mentions you or replies to you.
class LowPriorityChats extends InboxView {
  const LowPriorityChats();
  @override
  String get title => 'Low Priority';
  @override
  bool operator ==(Object other) => other is LowPriorityChats;
  @override
  int get hashCode => 4;
}

/// Note to Self: the Switchboard note plus each network's
/// own chat with yourself (Signal's Note to Self, WhatsApp's message
/// yourself, Telegram's Saved Messages).
class NotesChats extends InboxView {
  const NotesChats();
  @override
  String get title => 'Notes';
  @override
  bool operator ==(Object other) => other is NotesChats;
  @override
  int get hashCode => 1;
}

class NetworkChats extends InboxView {
  const NetworkChats(this.network);
  final Network network;
  @override
  String get title => network.name;
  @override
  bool operator ==(Object other) => other is NetworkChats && other.network.id == network.id;
  @override
  int get hashCode => network.id.hashCode;
}

/// One linked account, when a network has more than one. Its chats are the
/// children of the bridge's personal space for that login.
class AccountChats extends InboxView {
  const AccountChats(this.network, this.login);
  final Network network;
  final BridgeLogin login;
  @override
  String get title => login.name;
  @override
  bool operator ==(Object other) => other is AccountChats && other.login.id == login.id && other.network.id == network.id;
  @override
  int get hashCode => Object.hash(network.id, login.id);
}

final selectedViewProvider = NotifierProvider<SelectedView, InboxView>(SelectedView.new);

class SelectedView extends Notifier<InboxView> {
  @override
  InboxView build() => const AllChats();
  void select(InboxView view) => state = view;
}

/// The Switchboard Note to Self room, once it exists. Rechecked when the
/// chat list grows or shrinks, as another device may have made it.
final noteToSelfIdProvider = FutureProvider<String?>((ref) async {
  ref.watch(roomListProvider.select((rooms) => rooms?.length));
  return ref.watch(coreProvider).noteToSelf(create: false);
});

/// Opens Note to Self, making it first if this is its first use.
Future<String?> ensureNoteToSelf(WidgetRef ref) async {
  final id = await ref.read(coreProvider).noteToSelf(create: true);
  ref.invalidate(noteToSelfIdProvider);
  return id;
}

/// Whether [room] is a chat with yourself: the Switchboard note, or a
/// bridged chat whose only other members are bridge bots.
bool isSelfChat(RoomSummary room, Set<String> bots, String? noteId) {
  if (room.id == noteId) return true;
  if (room.network == null || room.isInvite || room.memberCount > 2) return false;
  return room.heroUserIds.every(bots.contains);
}

/// The IDs of every chat with yourself, for the Notes view and avatars.
final selfChatIdsProvider = Provider<Set<String>>((ref) {
  final rooms = ref.watch(roomListProvider) ?? const [];
  final bots = ref.watch(bridgeBotsProvider);
  final noteId = ref.watch(noteToSelfIdProvider).value;
  return {for (final r in rooms) if (isSelfChat(r, bots, noteId)) r.id};
});

/// Whether a chat is with yourself. False when the list can't be read
/// (signed out, or in widget tests that don't provide it).
final isSelfChatProvider = Provider.family<bool, String>((ref, roomId) {
  try {
    return ref.watch(selfChatIdsProvider).contains(roomId);
  } catch (_) {
    return false;
  }
});

/// The linked account a bridged chat belongs to, when its network has
/// several: the login whose personal space holds the chat. Null while
/// that loads, or when there is only one account.
final roomAccountProvider = Provider.family<BridgeLogin?, String>((ref, roomId) {
  final network = ref.watch(roomSummaryProvider(roomId).select((r) => r?.network));
  if (network == null) return null;
  final bridges = ref.watch(bridgesProvider).value ?? const [];
  final logins = [
    for (final b in bridges)
      if (b.protocolId == network.id)
        for (final l in b.logins)
          if (l.spaceRoom != null) l,
  ];
  if (logins.length < 2) return null;
  for (final l in logins) {
    if (ref.watch(spaceChildrenProvider(l.spaceRoom!)).value?.contains(roomId) ?? false) return l;
  }
  return null;
});

/// Rooms in a space. Recomputed when the chat list grows or shrinks, since
/// bridges add portals to the account space as chats appear.
final spaceChildrenProvider = FutureProvider.family<Set<String>, String>((ref, spaceId) async {
  ref.watch(roomListProvider.select((rooms) => rooms?.length));
  return (await ref.watch(coreProvider).spaceChildren(spaceId: spaceId)).toSet();
});

/// Every view on offer: all chats, each network that has chats or an
/// enabled bridge, and each account where a network has several.
final viewsProvider = Provider<List<InboxView>>((ref) {
  final rooms = ref.watch(roomListProvider) ?? const [];
  final bridges = ref.watch(bridgesProvider).value ?? const [];
  return inboxViews(rooms, bridges);
});

List<InboxView> inboxViews(List<RoomSummary> rooms, List<Bridge> bridges) {
  // Only networks with an account linked. Until the Hub has
  // answered, the networks the chats come from stand in.
  final networks = <String, Network>{};
  for (final b in bridges) {
    if (b.logins.isEmpty) continue;
    networks[b.protocolId] = Network(id: b.protocolId, name: b.network, avatarMxc: b.iconMxc);
  }
  if (bridges.isEmpty) {
    for (final r in rooms) {
      final n = r.network;
      if (n != null) networks.putIfAbsent(n.id, () => n);
    }
  }
  final sorted = networks.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return [
    const AllChats(),
    const FavouriteChats(),
    const NotesChats(),
    const LowPriorityChats(),
    const ArchivedChats(),
    for (final n in sorted) ...[
      NetworkChats(n),
      ...accountViews(n, bridges),
    ],
  ];
}

List<InboxView> accountViews(Network n, List<Bridge> bridges) {
  final logins = [
    for (final b in bridges)
      if (b.protocolId == n.id)
        for (final l in b.logins)
          if (l.spaceRoom != null) l,
  ];
  return logins.length < 2 ? const [] : [for (final l in logins) AccountChats(n, l)];
}

/// Whether [room] belongs in [view]. [spaceRooms] is the account's space
/// children, or null while they load (the network filter applies then).
/// Whether a chat is archived: archived, and nobody else has written
/// since. Your own messages don't bring it back; marking it unread does.
bool isArchived(RoomSummary room, {bool? override}) {
  if (override != null) return override;
  final at = room.archivedAt;
  if (at == null || room.isMarkedUnread) return false;
  final p = room.preview;
  final newer = p != null && !p.isOwn && (room.timestampMs ?? 0) > at;
  return !newer;
}

/// Archive and unarchive taps not yet echoed by the server, so the list
/// changes at once.
final archiveOverridesProvider = NotifierProvider<ArchiveOverrides, Map<String, bool>>(ArchiveOverrides.new);

class ArchiveOverrides extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() {
    // Drop an override once the room says the same by itself.
    ref.listen(roomListProvider, (_, rooms) {
      if (rooms == null || state.isEmpty) return;
      final byId = {for (final r in rooms) r.id: r};
      final settled = {
        for (final MapEntry(key: id, value: archived) in state.entries)
          if (byId[id] case final r? when isArchived(r) == archived) id,
      };
      if (settled.isNotEmpty) state = {...state}..removeWhere((id, _) => settled.contains(id));
    });
    return const {};
  }

  void set(Iterable<String> ids, bool archived) => state = {...state, for (final id in ids) id: archived};
  void clear(Iterable<String> ids) => state = {...state}..removeWhere((id, _) => ids.contains(id));
}

/// Archives chats or brings them back, showing it at once.
Future<void> setArchived(WidgetRef ref, Iterable<String> roomIds, bool archived) async {
  final ids = roomIds.toList();
  ref.read(archiveOverridesProvider.notifier).set(ids, archived);
  try {
    await ref.read(coreProvider).setArchived(roomIds: ids, archived: archived);
  } catch (_) {
    ref.read(archiveOverridesProvider.notifier).clear(ids);
    rethrow;
  }
}

/// Moves chats to Low Priority, or back to the inbox.
Future<void> setLowPriority(WidgetRef ref, Iterable<String> roomIds, bool lowPriority) =>
    ref.read(coreProvider).setLowPriority(roomIds: roomIds.toList(), lowPriority: lowPriority);

/// Marks chats read, or unread.
Future<void> setRead(WidgetRef ref, Iterable<String> roomIds, bool read) {
  final core = ref.read(coreProvider);
  final ids = roomIds.toList();
  return read ? core.markRoomsRead(roomIds: ids) : core.setMarkedUnread(roomIds: ids, unread: true);
}

bool isUnread(RoomSummary r) => r.unreadCount > 0 || r.isMarkedUnread;

/// Whether the chat looks unread in the list. A Low Priority chat's new
/// messages show, but quietly: they don't notify, so [isUnread], which
/// the badges count, leaves them out.
bool looksUnread(RoomSummary r) => isUnread(r) || (r.isLowPriority && r.unreadMessages > 0);

/// Chats picked in select mode; null when not selecting.
final selectionProvider = NotifierProvider<Selection, Set<String>?>(Selection.new);

class Selection extends Notifier<Set<String>?> {
  @override
  Set<String>? build() => null;
  void start([String? first]) => state = {?first};
  void toggle(String id) {
    final s = state ?? {};
    state = s.contains(id) ? ({...s}..remove(id)) : {...s, id};
  }

  void selectAll(Iterable<String> ids) => state = {...?state, ...ids};
  void end() => state = null;
}

bool inView(RoomSummary room, InboxView view,
        {Set<String>? spaceRooms, Set<String> selfChats = const {}, bool archived = false}) =>
    view is ArchivedChats ? archived : !archived && _inView(room, view, spaceRooms: spaceRooms, selfChats: selfChats);

bool _inView(RoomSummary room, InboxView view, {Set<String>? spaceRooms, Set<String> selfChats = const {}}) =>
    switch (view) {
      ArchivedChats() => true,
      LowPriorityChats() => room.isLowPriority,
      // Low Priority chats live in their own view only.
      _ when room.isLowPriority => false,
      AllChats() => true,
      FavouriteChats() => room.isFavourite,
      NotesChats() => selfChats.contains(room.id),
      NetworkChats(:final network) => room.network?.id == network.id,
      AccountChats(:final network) => room.network?.id == network.id && (spaceRooms?.contains(room.id) ?? true),
    };

/// The selected view's chats, without the bridge bots' management chats.
final viewRoomsProvider = Provider<List<RoomSummary>?>((ref) {
  final rooms = ref.watch(inboxProvider);
  final view = ref.watch(selectedViewProvider);
  if (rooms == null) return null;
  final space = switch (view) {
    AccountChats(:final login) => ref.watch(spaceChildrenProvider(login.spaceRoom!)).value,
    _ => null,
  };
  final selfChats = view is NotesChats ? ref.watch(selfChatIdsProvider) : const <String>{};
  final overrides = ref.watch(archiveOverridesProvider);
  return [
    for (final r in rooms)
      if (inView(r, view, spaceRooms: space, selfChats: selfChats, archived: isArchived(r, override: overrides[r.id]))) r,
  ];
});

/// The selected view's chats as the list draws them: the pinned grid, then
/// the rest newest first. [inView] keeps Low Priority chats to their view.
final listedRoomsProvider = Provider<({List<RoomSummary> pinned, List<RoomSummary> rest})?>((ref) {
  final rooms = ref.watch(viewRoomsProvider);
  if (rooms == null) return null;
  return (
    pinned: byFavouriteOrder([for (final r in rooms) if (r.isFavourite) r]),
    rest: [for (final r in rooms) if (!r.isFavourite) r],
  );
});

/// Favourites in their drag order; ones without an order go last, newest
/// first. The list arrives newest first, and the sort keeps that for ties.
List<RoomSummary> byFavouriteOrder(List<RoomSummary> rooms) {
  final indexed = rooms.indexed.toList()
    ..sort((a, b) {
      final oa = a.$2.favouriteOrder, ob = b.$2.favouriteOrder;
      if (oa != null && ob != null && oa != ob) return oa.compareTo(ob);
      if (oa != null && ob == null) return -1;
      if (oa == null && ob != null) return 1;
      return a.$1.compareTo(b.$1);
    });
  return [for (final (_, r) in indexed) r];
}

/// Orders for [count] favourites, evenly spread between 0 and 1 as the
/// `m.favourite` tag's order expects.
List<double> spreadOrders(int count) => [for (var i = 0; i < count; i++) (i + 1) / (count + 1)];

/// The order that puts a new favourite after [current] ones.
double orderAfter(List<RoomSummary> current) {
  final last = current.map((r) => r.favouriteOrder ?? 0).fold<double>(0, (a, b) => b > a ? b : a);
  return last + (1 - last) / 2;
}

/// Adds [room] to the favourites (at the end) or takes it out. It shows at
/// once and reaches the server when there is a connection.
Future<void> setFavourite(WidgetRef ref, RoomSummary room, bool favourite) async {
  final current = ref.read(listedRoomsProvider)?.pinned ?? const [];
  ref
      .read(pendingFavouritesProvider.notifier)
      .set(room.id, favourite: favourite, order: favourite ? orderAfter(current) : null);
}

/// Saves a new drag order: every favourite gets a fresh, evenly spread
/// order, so repeated moves never run out of room between two values.
Future<void> reorderFavourites(WidgetRef ref, List<RoomSummary> ordered) async {
  final pending = ref.read(pendingFavouritesProvider.notifier);
  final orders = spreadOrders(ordered.length);
  for (final (i, r) in ordered.indexed) {
    if (r.favouriteOrder != orders[i]) pending.set(r.id, favourite: true, order: orders[i]);
  }
}

/// The chat [step] places from [current] in [order], stopping at the ends.
/// With no current chat, the first one going down or the last going up.
String? stepChat(List<RoomSummary> order, String? current, int step) {
  if (order.isEmpty) return null;
  final i = order.indexWhere((r) => r.id == current);
  if (i < 0) return (step > 0 ? order.first : order.last).id;
  return order[(i + step).clamp(0, order.length - 1)].id;
}

/// The next unread chat below [current], wrapping to the top. Counts a Low
/// Priority chat's quiet messages too, so the shortcut works in that view.
String? nextUnread(List<RoomSummary> order, String? current) {
  final i = order.indexWhere((r) => r.id == current);
  for (var n = 1; n <= order.length; n++) {
    final r = order[(i + n) % order.length];
    if (r.id != current && looksUnread(r)) return r.id;
  }
  return null;
}

/// Chats whose name contains [query], ignoring case: names starting with it
/// first, each group newest first.
List<RoomSummary> jumpMatches(List<RoomSummary> rooms, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return rooms;
  final starts = <RoomSummary>[];
  final contains = <RoomSummary>[];
  for (final r in rooms) {
    final name = r.name.toLowerCase();
    if (name.startsWith(q)) {
      starts.add(r);
    } else if (name.contains(q)) {
      contains.add(r);
    }
  }
  return [...starts, ...contains];
}

/// How many chats in a view are unread.
final viewUnreadProvider = Provider.family<int, InboxView>((ref, view) {
  final rooms = ref.watch(inboxProvider) ?? const [];
  final space = switch (view) {
    AccountChats(:final login) => ref.watch(spaceChildrenProvider(login.spaceRoom!)).value,
    _ => null,
  };
  final selfChats = view is NotesChats ? ref.watch(selfChatIdsProvider) : const <String>{};
  final overrides = ref.watch(archiveOverridesProvider);
  return rooms
      .where((r) =>
          isUnread(r) &&
          inView(r, view, spaceRooms: space, selfChats: selfChats, archived: isArchived(r, override: overrides[r.id])))
      .length;
});
