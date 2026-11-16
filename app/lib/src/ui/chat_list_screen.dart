import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../rust/api/types.dart';
import '../state/push.dart';
import '../state/session.dart';
import '../state/views.dart';
import 'format.dart';
import 'layout.dart';
import 'search_screen.dart';
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/connection_banner.dart';
import 'widgets/health_banner.dart';

class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(selectedViewProvider);
    return Scaffold(
      appBar: AppBar(
        // The title switches views; the chevron says it can be tapped.
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => showViewSwitcher(context),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(view.title, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 2),
              const Icon(Icons.keyboard_arrow_down_rounded, size: 26),
            ],
          ),
        ),
        actions: const [ChatListMenu()],
      ),
      body: const ChatList(),
      bottomNavigationBar: const _BottomBar(),
    );
  }
}

/// Accounts and Sign out, plus Settings on desktop.
class ChatListMenu extends ConsumerWidget {
  const ChatListMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (v) async {
        switch (v) {
          case 'select':
            ref.read(selectionProvider.notifier).start();
          case 'readAll':
            // looksUnread: in Low Priority, the grey counts too.
            final unread = [for (final r in ref.read(viewRoomsProvider) ?? const <RoomSummary>[]) if (looksUnread(r)) r.id];
            if (unread.isEmpty) return;
            try {
              await setRead(ref, unread, true);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't mark all read: $e")));
              }
            }
          case 'accounts':
            context.push('/accounts');
          case 'settings':
            context.push('/settings');
          case 'notifications':
            context.push('/notifications');
          case 'signout':
            await ref.read(sessionProvider.notifier).logout();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'select', child: Text('Select chats')),
        const PopupMenuItem(value: 'readAll', child: Text('Mark all as read')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'accounts', child: Text('Accounts')),
        if (isDesktop) const PopupMenuItem(value: 'settings', child: Text('Settings')),
        if (pushSupported) const PopupMenuItem(value: 'notifications', child: Text('Notifications')),
        const PopupMenuItem(value: 'signout', child: Text('Sign out')),
      ],
    );
  }
}

/// The banners and the selected view's chats. [selectedRoomId] is the chat
/// open beside the list on wide windows.
class ChatList extends ConsumerWidget {
  const ChatList({super.key, this.selectedRoomId});
  final String? selectedRoomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Signed in: re-register for push, since APNs tokens can change.
    ref.watch(readHiddenChatsProvider);
    if (pushSupported) {
      ref.watch(pushProvider);
      ref.watch(notificationTidyProvider);
    }
    final rooms = ref.watch(viewRoomsProvider);
    final view = ref.watch(selectedViewProvider);
    final listed = ref.watch(listedRoomsProvider);
    final note = ref.watch(noteToSelfIdProvider);
    final noteMissing = note.hasValue && note.value == null;
    final archiveView = view is ArchivedChats;
    // The Archive is a plain list: favourites lose their grid there.
    final pinned = archiveView ? const <RoomSummary>[] : listed?.pinned ?? const [];
    final rest = archiveView ? rooms ?? const <RoomSummary>[] : listed?.rest ?? const [];
    final selected = ref.watch(selectionProvider);
    final swipes = !isDesktop && selected == null;

    Widget row(RoomSummary r) {
      final chat = ChatRow(room: r, selected: r.id == selectedRoomId);
      return swipes ? _SwipeRow(key: ValueKey(r.id), room: r, archiveView: archiveView, child: chat) : chat;
    }

    return Column(
      children: [
        if (selected != null)
          _SelectionBar(
            selected: selected,
            visible: [...pinned, ...rest],
            archiveView: archiveView,
            lowPriorityView: view is LowPriorityChats,
          ),
        const ConnectionBanner(),
        const HealthBanner(),
        Expanded(
          child: switch (rooms) {
            null => const Center(child: CircularProgressIndicator()),
            [] when view is AllChats => const _EmptyInbox(),
            [] when view is ArchivedChats => const _NoArchived(),
            [] when view is LowPriorityChats => const _NoLowPriority(),
            [] when view is NotesChats => const Center(child: SingleChildScrollView(child: StartNoteToSelf(large: true))),
            [] when view is FavouriteChats => const _NoFavourites(),
            final rooms when view is FavouriteChats =>
              _FavouritesList(rooms: byFavouriteOrder(rooms), selectedRoomId: selectedRoomId),
            [] => Center(child: Text('No ${view.title} chats yet')),
            _ => CustomScrollView(
                slivers: [
                  if (view is NotesChats && noteMissing) const SliverToBoxAdapter(child: StartNoteToSelf()),
                  if (pinned.isNotEmpty)
                    SliverToBoxAdapter(child: _PinnedGrid(rooms: pinned, selectedRoomId: selectedRoomId)),
                  SliverList.builder(
                    itemCount: rest.length,
                    itemBuilder: (context, i) => row(rest[i]),
                  ),
                ],
              ),
          },
        ),
      ],
    );
  }
}

/// The mobile bottom bar: search, then the view switcher on the right.
class _BottomBar extends ConsumerWidget {
  const _BottomBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(selectedViewProvider);
    final scheme = Theme.of(context).colorScheme;
    final elsewhere = ref.watch(viewsProvider).where((v) => v != view).fold<int>(
          0,
          (n, v) => n + (v is NetworkChats || v is AllChats ? ref.watch(viewUnreadProvider(v)) : 0),
        );
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant, width: 0.5))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Material(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => openSearch(context),
                    child: SizedBox(
                      height: 36,
                      child: Row(
                        children: [
                          const SizedBox(width: 10),
                          Icon(Icons.search_rounded, size: 20, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Text('Search', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // A long view name shortens rather than squeezing search out.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.6),
                child: TextButton.icon(
                  onPressed: () => showViewSwitcher(context),
                  icon: Badge(
                    isLabelVisible: elsewhere > 0,
                    smallSize: 8,
                    backgroundColor: scheme.primary,
                    child: ViewIcon(view: view, size: 22),
                  ),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          view.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const Icon(Icons.unfold_more_rounded, size: 18),
                    ],
                  ),
                  style: TextButton.styleFrom(foregroundColor: scheme.onSurface),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class ViewIcon extends StatelessWidget {
  const ViewIcon({super.key, required this.view, this.size = 28});
  final InboxView view;
  final double size;

  @override
  Widget build(BuildContext context) => switch (view) {
        AllChats() => Icon(Icons.inbox_rounded, size: size),
        FavouriteChats() => Icon(Icons.star_rounded, size: size, color: favouriteColor),
        LowPriorityChats() => Icon(Icons.low_priority_rounded, size: size),
        ArchivedChats() => Icon(Icons.archive_outlined, size: size),
        NotesChats() => NoteAvatar(size: size),
        NetworkChats(:final network) => NetworkBadge(network: network, size: size - 4),
        AccountChats(:final login, :final network) => SizedBox(
            width: size,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                MxcAvatar(name: login.name, mxc: login.avatar, size: size),
                Positioned(right: -3, bottom: -3, child: NetworkBadge(network: network, size: size * 0.4)),
              ],
            ),
          ),
      };
}

/// Lists every view with its unread count.
Future<void> showViewSwitcher(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => Consumer(
      builder: (context, ref, _) {
        final views = ref.watch(viewsProvider);
        final selected = ref.watch(selectedViewProvider);
        final scheme = Theme.of(context).colorScheme;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final v in views)
                ListTile(
                  contentPadding: EdgeInsets.only(left: v is AccountChats ? 40 : 16, right: 16),
                  leading: ViewIcon(view: v),
                  title: Text(v.title, style: TextStyle(fontWeight: v == selected ? FontWeight.w700 : FontWeight.w500)),
                  subtitle: v is AccountChats && v.login.handle != null ? Text(v.login.handle!) : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ref.watch(viewUnreadProvider(v)) case final n when n > 0)
                        Text('$n', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)),
                      if (v == selected) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.check_rounded, color: scheme.primary),
                      ],
                    ],
                  ),
                  onTap: () {
                    ref.read(selectedViewProvider.notifier).select(v);
                    Navigator.pop(sheet);
                  },
                ),
            ],
          ),
        );
      },
    ),
  );
}

/// Starts the Switchboard Note to Self: a chat with only you in it, for
/// links, drafts and reminders. [large] is the Notes view's empty state.
class StartNoteToSelf extends ConsumerStatefulWidget {
  const StartNoteToSelf({super.key, this.large = false});
  final bool large;

  @override
  ConsumerState<StartNoteToSelf> createState() => _StartNoteToSelfState();
}

class _StartNoteToSelfState extends ConsumerState<StartNoteToSelf> {
  bool _busy = false;

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final id = await ensureNoteToSelf(ref);
      if (id != null && mounted) openRoom(context, id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't start Note to Self: $e")));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const blurb = 'A chat with only you in it, for links, drafts and reminders.';
    if (!widget.large) {
      return ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        leading: const NoteAvatar(size: 52),
        title: const Text('Note to Self', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        subtitle: Text(blurb, style: TextStyle(color: scheme.onSurfaceVariant)),
        trailing: _busy
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(Icons.add_rounded, color: scheme.primary),
        onTap: _busy ? null : _start,
      );
    }
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const NoteAvatar(size: 72),
          const SizedBox(height: 16),
          Text('Note to Self', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(blurb, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
            onPressed: _busy ? null : _start,
            child: _busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Start Note to Self'),
          ),
        ],
      ),
    );
  }
}

/// The favourites as a list you can drag to reorder; the order is saved in
/// the `m.favourite` tags, so the inbox grid and every device follow it.
class _FavouritesList extends ConsumerStatefulWidget {
  const _FavouritesList({required this.rooms, this.selectedRoomId});
  final List<RoomSummary> rooms;
  final String? selectedRoomId;

  @override
  ConsumerState<_FavouritesList> createState() => _FavouritesListState();
}

class _FavouritesListState extends ConsumerState<_FavouritesList> {
  /// The order just dragged into, shown until the server's tags catch up.
  List<String>? _pending;

  @override
  void didUpdateWidget(_FavouritesList old) {
    super.didUpdateWidget(old);
    final pending = _pending;
    if (pending != null && listEquals([for (final r in widget.rooms) r.id], pending)) _pending = null;
  }

  @override
  Widget build(BuildContext context) {
    final byId = {for (final r in widget.rooms) r.id: r};
    // Keep the dragged order with fresh rows, without chats that stopped
    // being favourites meanwhile.
    final rooms = _pending == null ? widget.rooms : [for (final id in _pending!) ?byId[id]];
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: rooms.length,
      onReorderItem: (from, to) {
        final next = [...rooms];
        next.insert(to, next.removeAt(from));
        setState(() => _pending = [for (final r in next) r.id]);
        reorderFavourites(ref, next).catchError((Object e) {
          if (!mounted || !context.mounted) return;
          setState(() => _pending = null);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't save the order: $e")));
        });
      },
      itemBuilder: (context, i) => Row(
        key: ValueKey(rooms[i].id),
        children: [
          Expanded(child: ChatRow(room: rooms[i], selected: rooms[i].id == widget.selectedRoomId)),
          ReorderableDragStartListener(
            index: i,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
              child: Icon(Icons.drag_handle_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoFavourites extends StatelessWidget {
  const _NoFavourites();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, size: 56, color: favouriteColor),
            const SizedBox(height: 16),
            Text('No favourites yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              isDesktop
                  ? 'Right-click a chat and choose Favourite. Favourites sit at the top of the inbox.'
                  : 'Press and hold a chat and choose Favourite. Favourites sit at the top of the inbox.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bar over the list in select mode: how many are picked, and what to
/// do with them.
class _SelectionBar extends ConsumerWidget {
  const _SelectionBar({
    required this.selected,
    required this.visible,
    required this.archiveView,
    required this.lowPriorityView,
  });
  final Set<String> selected;
  final List<RoomSummary> visible;
  final bool archiveView;
  final bool lowPriorityView;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selection = ref.read(selectionProvider.notifier);
    final picked = [for (final r in visible) if (selected.contains(r.id)) r];
    final allPicked = visible.isNotEmpty && picked.length == visible.length;

    Future<void> act(Future<void> Function() action, String failure) async {
      try {
        await action();
        selection.end();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$failure: $e')));
        }
      }
    }

    final ids = [for (final r in picked) r.id];
    return Material(
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              IconButton(icon: const Icon(Icons.close_rounded), tooltip: 'Done', onPressed: selection.end),
              Expanded(
                child: Text(
                  picked.isEmpty ? 'Select chats' : '${picked.length} selected',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: allPicked ? 'Select none' : 'Select all',
                icon: Icon(allPicked ? Icons.deselect_rounded : Icons.select_all_rounded),
                onPressed: () => allPicked ? selection.start() : selection.selectAll([for (final r in visible) r.id]),
              ),
              IconButton(
                tooltip: 'Mark read',
                icon: const Icon(Icons.mark_chat_read_outlined),
                onPressed: ids.isEmpty ? null : () => act(() => setRead(ref, ids, true), "Couldn't mark read"),
              ),
              IconButton(
                tooltip: 'Mark unread',
                icon: const Icon(Icons.mark_chat_unread_outlined),
                onPressed: ids.isEmpty ? null : () => act(() => setRead(ref, ids, false), "Couldn't mark unread"),
              ),
              IconButton(
                tooltip: archiveView ? 'Unarchive' : 'Archive',
                icon: Icon(archiveView ? Icons.unarchive_outlined : Icons.archive_outlined),
                onPressed: ids.isEmpty
                    ? null
                    : () => act(() => setArchived(ref, ids, !archiveView), archiveView ? "Couldn't unarchive" : "Couldn't archive"),
              ),
              IconButton(
                tooltip: lowPriorityView ? 'Remove from Low Priority' : 'Move to Low Priority',
                icon: Icon(lowPriorityView ? Icons.move_to_inbox_outlined : Icons.low_priority_rounded),
                onPressed: ids.isEmpty
                    ? null
                    : () => act(() => setLowPriority(ref, ids, !lowPriorityView), "Couldn't update Low Priority"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row that swipes: left archives (or, in the Archive,
/// brings back), right toggles read and unread. Phones only; desktop has
/// right-click and shortcuts.
class _SwipeRow extends ConsumerWidget {
  const _SwipeRow({super.key, required this.room, required this.archiveView, required this.child});
  final RoomSummary room;
  final bool archiveView;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final unread = isUnread(room);
    Widget background(Alignment align, Color color, IconData icon, String label) => Container(
          color: color,
          alignment: align,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
        );
    return Dismissible(
      key: ValueKey('swipe-${room.id}'),
      background: background(
        Alignment.centerLeft,
        scheme.primary,
        unread ? Icons.mark_chat_read_outlined : Icons.mark_chat_unread_outlined,
        unread ? 'Read' : 'Unread',
      ),
      secondaryBackground: background(
        Alignment.centerRight,
        const Color(0xFF5B6270),
        archiveView ? Icons.unarchive_outlined : Icons.archive_outlined,
        archiveView ? 'Unarchive' : 'Archive',
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          // Read and unread keep the row where it is.
          setRead(ref, [room.id], unread).catchError((Object e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't update: $e")));
            }
          });
          return false;
        }
        return true;
      },
      onDismissed: (_) {
        final messenger = ScaffoldMessenger.of(context);
        final archive = !archiveView;
        setArchived(ref, [room.id], archive).catchError((Object e) {
          messenger.showSnackBar(SnackBar(content: Text("Couldn't ${archive ? 'archive' : 'unarchive'}: $e")));
        });
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(archive ? 'Archived ${room.name}' : 'Moved ${room.name} to the inbox'),
            action: SnackBarAction(label: 'Undo', onPressed: () => setArchived(ref, [room.id], !archive)),
          ));
      },
      child: child,
    );
  }
}

class _NoArchived extends StatelessWidget {
  const _NoArchived();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.archive_outlined, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('Nothing archived', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              isDesktop
                  ? 'Archive a chat with Ctrl+E or from its right-click menu. It comes back when someone writes.'
                  : 'Swipe a chat left to archive it. It comes back when someone writes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoLowPriority extends StatelessWidget {
  const _NoLowPriority();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.low_priority_rounded, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No Low Priority chats', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '${isDesktop ? 'Right-click' : 'Press and hold'} a chat and choose Move to Low Priority. '
              "It leaves the inbox and only notifies you when someone mentions you or replies to you.",
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// A chat's menu: press and hold on phones, right-click on desktop.
Future<void> showChatMenu(BuildContext context, WidgetRef ref, RoomSummary room, {Offset? at}) async {
  final messenger = ScaffoldMessenger.of(context);
  final archived = isArchived(room, override: ref.read(archiveOverridesProvider)[room.id]);
  final unread = looksUnread(room);
  Future<void> run(Future<void> Function() action, String failure) async {
    try {
      await action();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$failure: $e')));
    }
  }

  final actions = <({IconData icon, Color? color, String label, Future<void> Function() run})>[
    (
      icon: room.isFavourite ? Icons.star_outline_rounded : Icons.star_rounded,
      color: favouriteColor,
      label: room.isFavourite ? 'Remove from Favourites' : 'Favourite',
      run: () => run(() => setFavourite(ref, room, !room.isFavourite), "Couldn't update favourites"),
    ),
    (
      icon: unread ? Icons.mark_chat_read_outlined : Icons.mark_chat_unread_outlined,
      color: null,
      label: unread ? 'Mark as read' : 'Mark as unread',
      run: () => run(() => setRead(ref, [room.id], unread), "Couldn't update"),
    ),
    (
      icon: archived ? Icons.unarchive_outlined : Icons.archive_outlined,
      color: null,
      label: archived ? 'Move to inbox' : 'Archive',
      run: () => run(() => setArchived(ref, [room.id], !archived), archived ? "Couldn't unarchive" : "Couldn't archive"),
    ),
    (
      icon: room.isLowPriority ? Icons.move_to_inbox_outlined : Icons.low_priority_rounded,
      color: null,
      label: room.isLowPriority ? 'Remove from Low Priority' : 'Move to Low Priority',
      run: () => run(() => setLowPriority(ref, [room.id], !room.isLowPriority), "Couldn't update Low Priority"),
    ),
    (
      icon: Icons.check_circle_outline_rounded,
      color: null,
      label: 'Select',
      run: () async => ref.read(selectionProvider.notifier).start(room.id),
    ),
  ];

  if (at != null) {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final chosen = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        for (final (i, a) in actions.indexed)
          PopupMenuItem(
            value: i,
            child: Row(children: [Icon(a.icon, color: a.color), const SizedBox(width: 12), Text(a.label)]),
          ),
      ],
    );
    if (chosen != null) await actions[chosen].run();
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: RoomAvatar(room: room, size: 40),
            title: Text(room.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const Divider(),
          for (final a in actions)
            ListTile(
              leading: Icon(a.icon, color: a.color),
              title: Text(a.label),
              onTap: () {
                Navigator.pop(sheet);
                a.run();
              },
            ),
        ],
      ),
    ),
  );
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No chats yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add an account to bring your chats in.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
              onPressed: () => context.push('/accounts/add'),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add account'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The favourites above the inbox, spaced by how many there are: up to four
/// share one row, more fill rows of three or four (whichever leaves the
/// last row fuller), and a short last row is centred. Each avatar carries
/// its unread count.
class _PinnedGrid extends ConsumerWidget {
  const _PinnedGrid({required this.rooms, this.selectedRoomId});
  final List<RoomSummary> rooms;
  final String? selectedRoomId;

  static int columnsFor(int count) {
    if (count <= 4) return count;
    final gaps3 = (3 - count % 3) % 3;
    final gaps4 = (4 - count % 4) % 4;
    return gaps3 < gaps4 ? 3 : 4;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final columns = columnsFor(rooms.length);
    final avatar = columns <= 3 ? 64.0 : 56.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: LayoutBuilder(
        builder: (context, box) {
          // Even shares of the width, capped so a few favourites on a wide
          // window stay together rather than drifting to the edges.
          final cell = (box.maxWidth / columns).floorToDouble().clamp(0.0, 128.0);
          return Wrap(
            alignment: WrapAlignment.center,
            runSpacing: 8,
            children: [
              for (final r in rooms)
                SizedBox(
                  width: cell,
                  child: _Favourite(room: r, avatarSize: avatar, selected: r.id == selectedRoomId),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Favourite extends ConsumerWidget {
  const _Favourite({required this.room, required this.avatarSize, required this.selected});
  final RoomSummary room;
  final double avatarSize;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final unread = room.unreadCount > 0 || room.isMarkedUnread;
    return GestureDetector(
      onSecondaryTapUp: (d) => showChatMenu(context, ref, room, at: d.globalPosition),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openRoom(context, room.id),
        onLongPress: () => showChatMenu(context, ref, room),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
          decoration: BoxDecoration(
            color: selected ? scheme.surfaceContainerHigh : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  RoomAvatar(room: room, size: avatarSize),
                  if (unread)
                    Positioned(
                      top: -4,
                      right: -6,
                      // A ring in the background colour keeps the count
                      // clear of the photo behind it.
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: _UnreadPill(count: room.unreadCount, mention: room.mentionCount > 0),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                room.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, fontWeight: unread ? FontWeight.w700 : FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatRow extends ConsumerWidget {
  const ChatRow({super.key, required this.room, this.selected = false});
  final RoomSummary room;

  /// Open beside the list.
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final unread = looksUnread(room);
    // A Low Priority chat's new messages don't notify: a grey count.
    final quiet = !isUnread(room);
    final preview = room.preview;
    final previewText = preview == null ? (room.isInvite ? 'Invited you' : '') : _previewText(room, preview);

    // In select mode a tap picks the chat, and its avatar shows a tick.
    final picking = ref.watch(selectionProvider.select((s) => s?.contains(room.id)));
    final row = InkWell(
      onTap: picking == null
          ? () => openRoom(context, room.id)
          : () => ref.read(selectionProvider.notifier).toggle(room.id),
      onLongPress: picking == null
          ? () => showChatMenu(context, ref, room)
          : () => ref.read(selectionProvider.notifier).toggle(room.id),
      onSecondaryTapUp: picking == null ? (d) => showChatMenu(context, ref, room, at: d.globalPosition) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            if (picking == null)
              RoomAvatar(room: room)
            else
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Opacity(opacity: picking ? 0.55 : 1, child: RoomAvatar(room: room)),
                  Positioned(
                    left: -2,
                    top: -2,
                    child: Container(
                      decoration: BoxDecoration(color: scheme.surface, shape: BoxShape.circle),
                      child: Icon(
                        picking ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                        size: 24,
                        color: picking ? scheme.primary : scheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          room.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: unread ? FontWeight.w700 : FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        listTime(room.timestampMs),
                        style: TextStyle(
                          fontSize: 12,
                          color: unread && !quiet ? scheme.primary : scheme.onSurfaceVariant,
                          fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (preview?.failed ?? false)
                        Padding(
                          padding: const EdgeInsets.only(right: 4, top: 1),
                          child: Icon(Icons.error_outline_rounded, size: 16, color: scheme.error),
                        ),
                      Expanded(
                        child: Text(
                          previewText,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.3,
                            color: unread ? scheme.onSurface : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (unread) ...[
                        const SizedBox(width: 8),
                        _UnreadPill(
                          count: quiet ? room.unreadMessages : room.unreadCount,
                          mention: room.mentionCount > 0,
                          quiet: quiet,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!selected) return row;
    return Material(color: scheme.surfaceContainerHigh, child: row);
  }

  static String _previewText(RoomSummary room, Preview p) {
    if (p.isOwn) return 'You: ${p.text}';
    if (room.isDm || p.senderName == null) return p.text;
    return '${p.senderName}: ${p.text}';
  }
}

class _UnreadPill extends StatelessWidget {
  const _UnreadPill({required this.count, required this.mention, this.quiet = false});
  final int count;
  final bool mention;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = mention ? '@' : (count > 0 ? (count > 99 ? '99+' : '$count') : '');
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: quiet ? scheme.outline : scheme.primary, borderRadius: BorderRadius.circular(10)),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}
