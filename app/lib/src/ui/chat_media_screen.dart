// A chat's photos and videos, files and links, newest first, as other chat
// apps show them. Pages come from the search index, then from the server's
// history once the index has nothing older (links come from the index only).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../rust/api/types.dart';
import '../state/media.dart';
import '../state/rooms.dart';
import '../state/search.dart';
import '../state/session.dart';
import 'format.dart';
import 'forward.dart';
import 'media_bubbles.dart';
import 'save_media.dart';
import 'search_screen.dart';
import 'widgets/avatar.dart';

typedef MediaKey2 = ({String roomId, MediaTab tab});

class MediaListState {
  const MediaListState({this.items = const [], this.loading = false, this.done = false, this.error});
  final List<IndexedMessage> items;
  final bool loading;
  final bool done;
  final Object? error;
}

/// One tab's entries, loaded a page at a time. Shared by the grid and the
/// full-screen viewer, which loads more as it nears the end.
final chatMediaProvider =
    NotifierProvider.autoDispose.family<ChatMediaNotifier, MediaListState, MediaKey2>(ChatMediaNotifier.new);

class ChatMediaNotifier extends Notifier<MediaListState> {
  ChatMediaNotifier(this.key);
  final MediaKey2 key;

  bool _started = false;
  String? _next;

  @override
  MediaListState build() {
    Future.microtask(loadMore);
    return const MediaListState(loading: true);
  }

  Future<void> loadMore() async {
    if (_started && (state.done || state.loading)) return;
    final first = !_started;
    _started = true;
    state = MediaListState(items: state.items, loading: true);
    final core = ref.read(coreProvider);
    var items = state.items;
    var done = false;
    try {
      // A page can come back short where the index ends and the server's
      // history starts; keep going until there's a screenful.
      for (var i = 0; i < 6; i++) {
        final page = await core.chatMedia(
          roomId: key.roomId,
          tab: key.tab,
          cursor: first && i == 0 ? null : _next,
          limit: 60,
        );
        if (!ref.mounted) return;
        items = [...items, ...page.items];
        _next = page.next;
        done = page.next == null;
        if (done || items.length - state.items.length >= 30) break;
      }
      state = MediaListState(items: items, done: done);
    } catch (e) {
      if (!ref.mounted) return;
      state = MediaListState(items: items, error: e);
    }
  }
}

class ChatMediaScreen extends ConsumerWidget {
  const ChatMediaScreen({super.key, required this.roomId});
  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final room = ref.watch(roomSummaryProvider(roomId));
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              if (room != null) ...[RoomAvatar(room: room, size: 32), const SizedBox(width: 10)],
              Expanded(child: Text(room?.name ?? 'Media', maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: 'Search in chat',
              onPressed: () => openSearch(context, roomId: roomId),
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Media'), Tab(text: 'Files'), Tab(text: 'Links')]),
        ),
        body: TabBarView(
          children: [
            _MediaGrid(roomId: roomId),
            _EntryList(key2: (roomId: roomId, tab: MediaTab.files)),
            _EntryList(key2: (roomId: roomId, tab: MediaTab.links)),
          ],
        ),
      ),
    );
  }
}

/// Shows a message in its chat, leaving the media pages.
void showInChat(BuildContext context, IndexedMessage m) {
  context.go('/room/${Uri.encodeComponent(m.roomId)}?event=${Uri.encodeComponent(m.eventId)}');
}

String _monthLabel(int ms) => DateFormat('MMMM y').format(DateTime.fromMillisecondsSinceEpoch(ms));

String _whoAndWhen(IndexedMessage m) {
  final who = m.isOwn ? 'You' : (m.senderName ?? m.sender);
  return '$who · ${listTime(m.timestampMs)}';
}

/// Loads the next page when the list nears its end.
bool _onScroll(ScrollNotification n, VoidCallback more) {
  if (n.metrics.pixels > n.metrics.maxScrollExtent - 600) more();
  return false;
}

class _Status extends StatelessWidget {
  const _Status({required this.state, required this.empty, required this.onRetry});
  final MediaListState state;
  final String empty;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (state.loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (state.error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text("Couldn't load more: ${state.error}", textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (state.done && state.items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(48),
        child: Text(empty, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant)),
      );
    }
    return const SizedBox(height: 24);
  }
}

class _MediaGrid extends ConsumerWidget {
  const _MediaGrid({required this.roomId});
  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (roomId: roomId, tab: MediaTab.media);
    final state = ref.watch(chatMediaProvider(key));
    final notifier = ref.read(chatMediaProvider(key).notifier);

    // Month by month, newest first.
    final groups = <(String, List<(int, IndexedMessage)>)>[];
    for (final (i, m) in state.items.indexed) {
      final label = _monthLabel(m.timestampMs);
      if (groups.isEmpty || groups.last.$1 != label) groups.add((label, []));
      groups.last.$2.add((i, m));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) => _onScroll(n, notifier.loadMore),
      child: CustomScrollView(
        slivers: [
          for (final (label, entries) in groups) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 130,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: entries.length,
              itemBuilder: (context, j) {
                final (index, m) = entries[j];
                return _MediaTile(
                  item: m,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    fullscreenDialog: true,
                    builder: (_) => MediaGallery(roomId: roomId, initial: index),
                  )),
                  onLongPress: () => _mediaMenu(context, ref, m),
                );
              },
            ),
          ],
          SliverToBoxAdapter(
            child: _Status(state: state, empty: 'No photos or videos yet', onRetry: notifier.loadMore),
          ),
        ],
      ),
    );
  }
}

/// Save, share, forward and show in chat, for a long press on a photo or
/// video.
void _mediaMenu(BuildContext context, WidgetRef ref, IndexedMessage m) {
  HapticFeedback.mediumImpact();
  final video = m.kind == MessageKind.video;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m.mxc != null) ...[
            ListTile(
              leading: Icon(saveMediaIcon),
              title: Text(saveMediaLabel),
              onTap: () {
                Navigator.pop(sheet);
                saveMedia(context, ref, mxc: m.mxc!, name: m.name ?? m.text, mimetype: m.mimetype, video: video);
              },
            ),
            if (canShareMedia)
              ListTile(
                leading: const Icon(shareMediaIcon),
                title: const Text('Share'),
                onTap: () {
                  Navigator.pop(sheet);
                  shareMedia(context, ref, mxc: m.mxc!, name: m.name ?? m.text, mimetype: m.mimetype, video: video);
                },
              ),
          ],
          ListTile(
            leading: const Icon(forwardIcon),
            title: const Text('Forward'),
            onTap: () {
              Navigator.pop(sheet);
              forwardMessage(context, ref, roomId: m.roomId, eventId: m.eventId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline_rounded),
            title: const Text('Show in chat'),
            onTap: () {
              Navigator.pop(sheet);
              showInChat(context, m);
            },
          ),
        ],
      ),
    ),
  );
}

class _MediaTile extends ConsumerWidget {
  const _MediaTile({required this.item, required this.onTap, required this.onLongPress});
  final IndexedMessage item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final video = item.kind == MessageKind.video;
    final thumb = video ? item.thumbnailMxc : item.mxc;
    final px = (130 * MediaQuery.devicePixelRatioOf(context)).round();
    final bytes = thumb == null ? null : ref.watch(mediaProvider((mxc: thumb, width: px, height: px))).value;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: Hero(
        tag: 'media-${item.eventId}',
        child: Stack(
          fit: StackFit.expand,
          children: [
            bytes == null
                ? ColoredBox(color: video ? Colors.black87 : scheme.surfaceContainerHigh)
                : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, semanticLabel: item.text),
            if (video)
              Positioned(
                left: 4,
                right: 4,
                bottom: 4,
                child: Row(
                  children: [
                    const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18, shadows: [Shadow(blurRadius: 4)]),
                    const Spacer(),
                    if (item.durationMs != null)
                      Text(
                        clock(Duration(milliseconds: item.durationMs!)),
                        style: const TextStyle(color: Colors.white, fontSize: 12, shadows: [Shadow(blurRadius: 4)]),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The Files and Links tabs.
class _EntryList extends ConsumerWidget {
  const _EntryList({required this.key2});
  final MediaKey2 key2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatMediaProvider(key2));
    final notifier = ref.read(chatMediaProvider(key2).notifier);
    final links = key2.tab == MediaTab.links;
    final period = ref.watch(indexStatusProvider).value?.periodDays;
    final scheme = Theme.of(context).colorScheme;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) => _onScroll(n, notifier.loadMore),
      child: ListView(
        children: [
          for (final m in state.items) links ? _LinkRow(item: m) : _FileRow(item: m),
          _Status(state: state, empty: links ? 'No links yet' : 'No files yet', onRetry: notifier.loadMore),
          // Links are found in the index only, so they go back as far as it.
          if (links && state.done && period != null && period != 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Text(
                'Links from ${periodPhrase(period)}, as far back as this device indexes messages.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _FileRow extends ConsumerStatefulWidget {
  const _FileRow({required this.item});
  final IndexedMessage item;

  @override
  ConsumerState<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends ConsumerState<_FileRow> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String failed) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.item;
    final scheme = Theme.of(context).colorScheme;
    final name = m.name ?? m.text;
    final mxc = m.mxc;
    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
        child: _busy
            ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(fileIcon(m.mimetype)),
      ),
      title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [if (m.size != null) fileSize(m.size), _whoAndWhen(m)].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: mxc == null
          ? null
          : () => _run(() => openChatFile(context, ref, mxc: mxc, name: name, mimetype: m.mimetype), "Couldn't open file"),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (v) {
          switch (v) {
            case 'save' when mxc != null:
              _run(() => saveChatFileAs(ref, mxc: mxc, name: name, mimetype: m.mimetype), "Couldn't save file");
            case 'chat':
              showInChat(context, m);
          }
        },
        itemBuilder: (_) => [
          if (mxc != null) const PopupMenuItem(value: 'save', child: Text('Save as…')),
          const PopupMenuItem(value: 'chat', child: Text('Show in chat')),
        ],
      ),
    );
  }
}

class _LinkRow extends ConsumerWidget {
  const _LinkRow({required this.item});
  final IndexedMessage item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = item;
    final url = m.url ?? '';
    final uri = Uri.tryParse(url);
    final scheme = Theme.of(context).colorScheme;
    final preview = ref.watch(linkPreviewProvider(url)).value;
    final image = preview?.imageMxc;
    final px = (44 * MediaQuery.devicePixelRatioOf(context)).round();
    final bytes = image == null ? null : ref.watch(mediaProvider((mxc: image, width: px, height: px))).value;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox.square(
          dimension: 44,
          child: bytes != null
              ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
              : ColoredBox(color: scheme.surfaceContainerHigh, child: const Icon(Icons.link_rounded)),
        ),
      ),
      title: Text(
        preview?.title ?? uri?.host ?? url,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('$url\n${_whoAndWhen(m)}', maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: true,
      onTap: uri == null ? null : () => launchUrl(uri, mode: LaunchMode.externalApplication),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (v) {
          switch (v) {
            case 'copy':
              Clipboard.setData(ClipboardData(text: url));
            case 'chat':
              showInChat(context, m);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'copy', child: Text('Copy link')),
          PopupMenuItem(value: 'chat', child: Text('Show in chat')),
        ],
      ),
    );
  }
}

/// Photos and videos full screen, swiping between them: pinch to zoom,
/// save, share, or show the message in its chat.
class MediaGallery extends ConsumerStatefulWidget {
  const MediaGallery({super.key, required this.roomId, required this.initial});
  final String roomId;
  final int initial;

  @override
  ConsumerState<MediaGallery> createState() => _MediaGalleryState();
}

class _MediaGalleryState extends ConsumerState<MediaGallery> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  MediaKey2 get _key => (roomId: widget.roomId, tab: MediaTab.media);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatMediaProvider(_key));
    final items = state.items;
    final current = _index < items.length ? items[_index] : null;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
        title: current == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    current.isOwn ? 'You' : (current.senderName ?? current.sender),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    DateFormat('d MMMM y, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(current.timestampMs)),
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
        actions: [
          if (current?.mxc != null) ...[
            IconButton(
              icon: Icon(saveMediaIcon),
              tooltip: saveMediaLabel,
              onPressed: () => saveMedia(context, ref,
                  mxc: current!.mxc!,
                  name: current.name ?? current.text,
                  mimetype: current.mimetype,
                  video: current.kind == MessageKind.video),
            ),
            if (canShareMedia)
              IconButton(
                icon: const Icon(shareMediaIcon),
                tooltip: 'Share',
                onPressed: () => shareMedia(context, ref,
                    mxc: current!.mxc!,
                    name: current.name ?? current.text,
                    mimetype: current.mimetype,
                    video: current.kind == MessageKind.video),
              ),
          ],
          if (current != null) ...[
            IconButton(
              icon: const Icon(forwardIcon),
              tooltip: 'Forward',
              onPressed: () => forwardMessage(context, ref, roomId: current.roomId, eventId: current.eventId),
            ),
            IconButton(
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              tooltip: 'Show in chat',
              onPressed: () => showInChat(context, current),
            ),
          ],
        ],
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: items.length,
        onPageChanged: (i) {
          setState(() => _index = i);
          if (i >= items.length - 5) ref.read(chatMediaProvider(_key).notifier).loadMore();
        },
        itemBuilder: (context, i) => _GalleryPage(item: items[i]),
      ),
    );
  }
}

class _GalleryPage extends ConsumerWidget {
  const _GalleryPage({required this.item});
  final IndexedMessage item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = item;
    final size = MediaQuery.sizeOf(context);
    final px = (size.width * MediaQuery.devicePixelRatioOf(context)).round();
    final aspect = (m.width != null && m.height != null && m.height! > 0) ? m.width! / m.height! : 1.0;
    final caption = m.name != null && m.text != m.name ? m.text : null;

    final Widget content;
    if (m.kind == MessageKind.video) {
      final thumb = m.thumbnailMxc;
      final bytes = thumb == null ? null : ref.watch(mediaProvider((mxc: thumb, width: px, height: (px / aspect).round()))).value;
      content = GestureDetector(
        onTap: m.mxc == null
            ? null
            : () => Navigator.of(context).push(MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (_) => VideoViewer(mxc: m.mxc, name: m.name ?? m.text),
                )),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (bytes != null) Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 48),
            ),
          ],
        ),
      );
    } else {
      final mxc = m.mxc!;
      final original = ref.watch(mediaProvider((mxc: mxc, width: 0, height: 0))).value;
      final thumb = ref.watch(mediaProvider((mxc: mxc, width: 130 * 3, height: 130 * 3))).value;
      final bytes = original ?? thumb;
      content = bytes == null
          ? const CircularProgressIndicator(color: Colors.white)
          : InteractiveViewer(
              maxScale: 5,
              child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true, semanticLabel: m.text),
            );
    }
    return Stack(
      children: [
        Center(child: Hero(tag: 'media-${m.eventId}', child: content)),
        if (caption != null && caption.trim().isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black54,
              padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
              child: Text(caption, style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
          ),
      ],
    );
  }
}
