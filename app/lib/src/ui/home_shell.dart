// The signed-in app around every inbox route. On a phone it is just the
// route. From 600 px the chat list stays on the left, and from 900 px the
// sidebar of views sits beside it; the route fills the rest.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import '../state/hub.dart';
import '../state/rooms.dart';
import '../state/views.dart';
import 'chat_list_screen.dart';
import 'layout.dart';
import 'search_screen.dart';
import 'widgets/avatar.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.location, required this.child});

  /// The current route, which says which chat is open.
  final Uri location;
  final Widget child;

  String? get roomId {
    final s = location.pathSegments;
    return s.length >= 2 && s[0] == 'room' ? s[1] : null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panes = panesOf(context);
    final body = panes == Panes.one
        ? child
        : Material(
            child: Row(
              children: [
                if (panes == Panes.three) const Sidebar(),
                SizedBox(width: 320, child: _ListPane(selectedRoomId: roomId, viewSwitcher: panes == Panes.two)),
                const VerticalDivider(width: 1),
                Expanded(child: child),
              ],
            ),
          );
    if (!isDesktop) return body;
    return _Shortcuts(roomId: roomId, child: body);
  }
}

/// What the inbox route shows: the chat list on a phone, or a prompt to
/// pick a chat beside the list.
class InboxHome extends StatelessWidget {
  const InboxHome({super.key});

  @override
  Widget build(BuildContext context) {
    if (panesOf(context) == Panes.one) return const ChatListScreen();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Pick a chat', style: TextStyle(color: scheme.onSurfaceVariant)),
            if (isDesktop) ...[
              const SizedBox(height: 4),
              Text(
                '${primaryLabel('K')} to jump to one',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ListPane extends ConsumerWidget {
  const _ListPane({required this.selectedRoomId, required this.viewSwitcher});
  final String? selectedRoomId;

  /// Without the sidebar, the title opens the view switcher, as on a phone.
  final bool viewSwitcher;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(selectedViewProvider);
    return Scaffold(
      appBar: AppBar(
        title: viewSwitcher
            ? GestureDetector(onTap: () => showViewSwitcher(context), child: Text(view.title))
            : Text(view.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: 'Search (${primaryLabel('F', shift: true)})',
            onPressed: () => openSearch(context),
          ),
          const ChatListMenu(),
        ],
      ),
      body: ChatList(selectedRoomId: selectedRoomId),
    );
  }
}

/// Views with unread counts and status dots, then Accounts and Settings.
/// Collapses from 220 px to icons at 64 px.
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key});

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final views = ref.watch(viewsProvider);
    final selected = ref.watch(selectedViewProvider);
    final bridges = ref.watch(bridgesProvider).value ?? const [];
    final scheme = Theme.of(context).colorScheme;

    Health? health(InboxView v) => switch (v) {
          AllChats() || FavouriteChats() || NotesChats() || LowPriorityChats() || ArchivedChats() => null,
          NetworkChats(:final network) => networkHealth(bridges, network.id),
          AccountChats(:final login) => loginHealth(login),
        };

    return Container(
      width: _collapsed ? 64 : 220,
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          Align(
            alignment: _collapsed ? Alignment.center : Alignment.centerRight,
            child: IconButton(
              icon: Icon(_collapsed ? Icons.chevron_right_rounded : Icons.chevron_left_rounded),
              tooltip: _collapsed ? 'Expand sidebar' : 'Collapse sidebar',
              onPressed: () => setState(() => _collapsed = !_collapsed),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final v in views)
                  _SidebarEntry(
                    icon: ViewIcon(view: v, size: 24),
                    label: v.title,
                    indent: v is AccountChats,
                    collapsed: _collapsed,
                    selected: v == selected,
                    unread: ref.watch(viewUnreadProvider(v)),
                    health: health(v),
                    onTap: () => ref.read(selectedViewProvider.notifier).select(v),
                  ),
              ],
            ),
          ),
          const Divider(),
          _SidebarEntry(
            icon: const Icon(Icons.manage_accounts_outlined),
            label: 'Accounts',
            collapsed: _collapsed,
            onTap: () => openPage(context, '/accounts'),
          ),
          _SidebarEntry(
            icon: const Icon(Icons.settings_outlined),
            label: 'Settings',
            collapsed: _collapsed,
            onTap: () => openPage(context, '/settings'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SidebarEntry extends StatelessWidget {
  const _SidebarEntry({
    required this.icon,
    required this.label,
    required this.collapsed,
    required this.onTap,
    this.indent = false,
    this.selected = false,
    this.unread = 0,
    this.health,
  });

  final Widget icon;
  final String label;
  final bool collapsed;
  final VoidCallback onTap;
  final bool indent;
  final bool selected;
  final int unread;
  final Health? health;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = health == null ? null : _HealthDot(health: health!);
    final Widget content = collapsed
        ? Tooltip(
            message: label,
            child: Badge(
              isLabelVisible: unread > 0,
              smallSize: 8,
              backgroundColor: scheme.primary,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  icon,
                  if (dot != null) Positioned(left: -2, bottom: -2, child: dot),
                ],
              ),
            ),
          )
        : Row(
            children: [
              SizedBox(width: indent ? 20 : 0),
              icon,
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
                ),
              ),
              if (dot != null) ...[dot, const SizedBox(width: 8)],
              if (unread > 0)
                Text('$unread', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)),
            ],
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 10, vertical: 8),
            child: collapsed ? Center(child: content) : content,
          ),
        ),
      ),
    );
  }
}

class _HealthDot extends StatelessWidget {
  const _HealthDot({required this.health});
  final Health health;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (health) {
      Health.connected => (const Color(0xFF34C759), 'Connected'),
      Health.reconnecting => (const Color(0xFFFFB020), 'Reconnecting'),
      Health.broken => (Theme.of(context).colorScheme.error, 'Needs attention'),
    };
    return Tooltip(
      message: label,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).colorScheme.surfaceContainerLow, width: 1),
        ),
      ),
    );
  }
}

/// Desktop shortcuts that work anywhere in the inbox. Ctrl is ⌘ on macOS.
class _Shortcuts extends ConsumerWidget {
  const _Shortcuts({required this.roomId, required this.child});
  final String? roomId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    List<RoomSummary> order() {
      final listed = ref.read(listedRoomsProvider);
      return listed == null ? const [] : [...listed.pinned, ...listed.rest];
    }

    void open(String? id) {
      if (id != null) openRoom(context, id);
    }

    void pinned(int n) {
      final pins = ref.read(listedRoomsProvider)?.pinned ?? const [];
      if (n <= pins.length) openRoom(context, pins[n - 1].id);
    }

    const digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];

    return CallbackShortcuts(
      bindings: {
        primaryKey(LogicalKeyboardKey.keyK): () => jumpToChat(context),
        primaryKey(LogicalKeyboardKey.keyF, shift: true): () => openSearch(context),
        // In a chat, search it; otherwise everything.
        primaryKey(LogicalKeyboardKey.keyF): () => openSearch(context, roomId: roomId),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () => open(stepChat(order(), roomId, 1)),
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () => open(stepChat(order(), roomId, -1)),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true, shift: true): () =>
            open(nextUnread(order(), roomId)),
        for (var i = 0; i < digits.length; i++) primaryKey(digits[i]): () => pinned(i + 1),
        primaryKey(LogicalKeyboardKey.comma): () => openPage(context, '/settings'),
        // Archive the open chat, and mark it unread.
        primaryKey(LogicalKeyboardKey.keyE): () {
          final id = roomId;
          if (id == null) return;
          final room = ref.read(roomSummaryProvider(id));
          final archived = room != null && isArchived(room, override: ref.read(archiveOverridesProvider)[id]);
          setArchived(ref, [id], !archived).ignore();
        },
        primaryKey(LogicalKeyboardKey.keyU, shift: true): () {
          final id = roomId;
          if (id != null) setRead(ref, [id], false).ignore();
        },
        const SingleActivator(LogicalKeyboardKey.escape): () => ref.read(selectionProvider.notifier).end(),
      },
      // Something must hold focus for the shortcuts to see keys.
      child: Focus(autofocus: true, child: child),
    );
  }
}

/// The command bar: type part of a chat's name, then Enter.
Future<void> jumpToChat(BuildContext context) async {
  final id = await showDialog<String>(context: context, builder: (_) => const _JumpBar());
  if (id != null && context.mounted) openRoom(context, id);
}

class _JumpBar extends ConsumerStatefulWidget {
  const _JumpBar();

  @override
  ConsumerState<_JumpBar> createState() => _JumpBarState();
}

class _JumpBarState extends ConsumerState<_JumpBar> {
  String _query = '';
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final matches = jumpMatches(ref.watch(inboxProvider) ?? const [], _query).take(20).toList();
    final index = matches.isEmpty ? 0 : _index.clamp(0, matches.length - 1);
    final scheme = Theme.of(context).colorScheme;

    void move(int step) {
      if (matches.isNotEmpty) setState(() => _index = (index + step).clamp(0, matches.length - 1));
    }

    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(16, 80, 16, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
                },
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Jump to chat',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                  onChanged: (q) => setState(() {
                    _query = q;
                    _index = 0;
                  }),
                  onSubmitted: (_) {
                    if (matches.isNotEmpty) Navigator.pop(context, matches[index].id);
                  },
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (i, r) in matches.indexed)
                    ListTile(
                      dense: true,
                      selected: i == index,
                      selectedTileColor: scheme.surfaceContainerHigh,
                      leading: RoomAvatar(room: r, size: 32),
                      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: r.network == null ? null : Text(r.network!.name),
                      onTap: () => Navigator.pop(context, r.id),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
