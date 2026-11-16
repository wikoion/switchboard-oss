// Search: chats by name and messages through the device's index, with a
// date filter and the server for what the index doesn't hold. A page on a
// phone; a panel over the app on wider windows.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../rust/api/types.dart';
import '../state/media.dart';
import '../state/rooms.dart';
import '../state/search.dart';
import '../state/session.dart';
import '../state/views.dart';
import 'format.dart';
import 'layout.dart';
import 'widgets/avatar.dart';

const _snippetStart = '';
const _snippetEnd = '';
const _pageSize = 50;

/// Opens search, across every chat or in [roomId].
Future<void> openSearch(BuildContext context, {String? roomId}) async {
  if (panesOf(context) == Panes.one) {
    await context.push(roomId == null ? '/search' : '/search?room=${Uri.encodeComponent(roomId)}');
    return;
  }
  final size = MediaQuery.sizeOf(context);
  // Where to go once the panel closes.
  final next = await showDialog<String>(
    context: context,
    builder: (dialog) => Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 640,
        height: math.min(720, size.height - 80),
        child: SearchPanel(
          roomId: roomId,
          onOpen: (roomId, eventId) => Navigator.pop(dialog, messagePath(roomId, eventId)),
          onSettings: () => Navigator.pop(dialog, '/settings/search'),
          onClose: () => Navigator.pop(dialog),
        ),
      ),
    ),
  );
  if (next != null && context.mounted) openPage(context, next);
}

/// A chat, opened at one of its messages, or at its newest without one.
String messagePath(String roomId, String? eventId) {
  final room = Uri.encodeComponent(roomId);
  return eventId == null ? '/room/$room' : '/room/$room?event=${Uri.encodeComponent(eventId)}';
}

/// The search page on a phone.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key, this.roomId, this.query});
  final String? roomId;
  final String? query;

  @override
  Widget build(BuildContext context) => SearchPanel(
        roomId: roomId,
        initialQuery: query,
        onOpen: (roomId, eventId) => openPage(context, messagePath(roomId, eventId)),
        onSettings: () => openPage(context, '/settings/search'),
        onClose: () => context.pop(),
      );
}

enum _When { any, today, week, month, year, custom }

class SearchPanel extends ConsumerStatefulWidget {
  const SearchPanel({
    super.key,
    this.roomId,
    this.initialQuery,
    required this.onOpen,
    required this.onSettings,
    required this.onClose,
  });

  /// Search in this chat only.
  final String? roomId;

  /// What to search for straight away (`/search?q=`).
  final String? initialQuery;

  /// A message ([eventId]) or a chat (null) was picked.
  final void Function(String roomId, String? eventId) onOpen;

  /// "Change" under the results: the search settings.
  final VoidCallback onSettings;
  final VoidCallback onClose;

  @override
  ConsumerState<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends ConsumerState<SearchPanel> {
  late final _text = TextEditingController(text: widget.initialQuery);
  final _scroll = ScrollController();
  Timer? _debounce;

  late String? _roomId = widget.roomId;
  _When _when = _When.any;
  DateTimeRange? _custom;

  /// Bumped by every new search, so a slow one's results are dropped.
  int _version = 0;
  List<SearchHit> _hits = const [];
  bool _loading = false;
  bool _more = false;
  Object? _error;

  bool _askedServer = false;
  bool _serverLoading = false;
  List<SearchHit> _server = const [];
  String? _serverNext;
  Object? _serverError;

  String get _query => _text.text.trim();

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 200), _search);
    });
    _scroll.addListener(() {
      if (_more && !_loading && _scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
        _search(more: true);
      }
    });
    if (_query.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The date filter as a time range in ms: from (inclusive), to (exclusive).
  ({int? since, int? until}) _range() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    int ago(int days) => now.subtract(Duration(days: days)).millisecondsSinceEpoch;
    return switch (_when) {
      _When.any => (since: null, until: null),
      _When.today => (since: today.millisecondsSinceEpoch, until: null),
      _When.week => (since: ago(7), until: null),
      _When.month => (since: ago(30), until: null),
      _When.year => (since: ago(365), until: null),
      _When.custom => (
          since: _custom?.start.millisecondsSinceEpoch,
          until: _custom == null ? null : DateUtils.addDaysToDate(_custom!.end, 1).millisecondsSinceEpoch,
        ),
    };
  }

  Future<void> _search({bool more = false}) async {
    final query = _query;
    final version = more ? _version : ++_version;
    if (!more) {
      setState(() {
        _hits = const [];
        _more = false;
        _error = null;
        _askedServer = false;
        _server = const [];
        _serverNext = null;
        _serverError = null;
      });
    }
    if (query.isEmpty) return;
    setState(() => _loading = true);
    final (:since, :until) = _range();
    try {
      final page = await ref.read(coreProvider).searchMessages(
            query: query,
            roomId: _roomId,
            sinceMs: since,
            untilMs: until,
            offset: more ? _hits.length : 0,
            limit: _pageSize,
          );
      if (!mounted || version != _version) return;
      setState(() {
        _hits = [..._hits, ...page];
        _more = page.length == _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || version != _version) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _searchServer() async {
    final version = _version;
    setState(() {
      _askedServer = true;
      _serverLoading = true;
      _serverError = null;
    });
    final (:since, :until) = _range();
    try {
      final page = await ref.read(coreProvider).searchServer(
            query: _query,
            roomId: _roomId,
            sinceMs: since,
            untilMs: until,
            next: _serverNext,
          );
      if (!mounted || version != _version) return;
      setState(() {
        _server = [..._server, ...page.hits];
        _serverNext = page.next;
        _serverLoading = false;
      });
    } catch (e) {
      if (!mounted || version != _version) return;
      setState(() {
        _serverError = e;
        _serverLoading = false;
      });
    }
  }

  Future<void> _pickWhen() async {
    final chosen = await showModalBottomSheet<_When>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final w in _When.values)
              ListTile(
                title: Text(_whenLabel(w, null)),
                trailing: w == _when ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.pop(sheet, w),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    if (chosen == _When.custom) {
      final now = DateTime.now();
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: now,
        initialDateRange: _custom,
        helpText: 'Messages sent between',
      );
      if (range == null) return;
      _custom = range;
    }
    setState(() => _when = chosen);
    _search();
  }

  String _whenLabel(_When w, DateTimeRange? custom) => switch (w) {
        _When.any => 'Any time',
        _When.today => 'Today',
        _When.week => 'Past week',
        _When.month => 'Past month',
        _When.year => 'Past year',
        _When.custom when custom != null => _rangeLabel(custom),
        _When.custom => 'Choose dates…',
      };

  static String _rangeLabel(DateTimeRange r) {
    final sameYear = r.start.year == r.end.year && r.end.year == DateTime.now().year;
    final f = sameYear ? DateFormat('d MMM') : DateFormat('d MMM y');
    return DateUtils.isSameDay(r.start, r.end) ? f.format(r.start) : '${f.format(r.start)} – ${f.format(r.end)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inbox = ref.watch(inboxProvider) ?? const <RoomSummary>[];
    final rooms = {for (final r in inbox) r.id: r};
    final status = ref.watch(indexStatusProvider).value;
    final query = _query;
    final scoped = _roomId == null ? null : rooms[_roomId];

    // Bridge bots' management chats aren't in the inbox, so they're not
    // searched either.
    final hits = [for (final h in _hits) if (rooms.containsKey(h.message.roomId)) h];
    final server = [for (final h in _server) if (rooms.containsKey(h.message.roomId)) h];
    final chats = _roomId != null || query.isEmpty ? const <RoomSummary>[] : jumpMatches(inbox, query).take(4).toList();

    Widget hitRow(SearchHit h) => _HitRow(
          hit: h,
          room: rooms[h.message.roomId],
          showRoom: _roomId == null,
          onTap: () => widget.onOpen(h.message.roomId, h.message.eventId),
        );

    final done = query.isNotEmpty && !_loading && !_more;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(panesOf(context) == Panes.one ? Icons.arrow_back_rounded : Icons.close_rounded),
          onPressed: widget.onClose,
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: scoped == null ? 'Search' : 'Search in ${scoped.name}',
            border: InputBorder.none,
            filled: false,
          ),
          onSubmitted: (_) {
            _debounce?.cancel();
            _search();
          },
        ),
        actions: [
          if (_text.text.isNotEmpty)
            IconButton(icon: const Icon(Icons.close_rounded), tooltip: 'Clear', onPressed: _text.clear),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                if (scoped != null) ...[
                  InputChip(
                    avatar: RoomAvatar(room: scoped, size: 20),
                    label: Text(scoped.name, overflow: TextOverflow.ellipsis),
                    deleteButtonTooltipMessage: 'Search all chats instead',
                    onDeleted: () {
                      setState(() => _roomId = null);
                      _search();
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                FilterChip(
                  avatar: const Icon(Icons.calendar_today_rounded, size: 16),
                  label: Text(_whenLabel(_when, _custom)),
                  selected: _when != _When.any,
                  showCheckmark: false,
                  onSelected: (_) => _pickWhen(),
                ),
              ],
            ),
          ),
          if (status != null && status.indexing && status.chatsDone < status.chats)
            _IndexingLine(status: status),
          Expanded(
            child: query.isEmpty
                ? _Hint(status: status, scoped: scoped)
                : ListView(
                    controller: _scroll,
                    children: [
                      if (chats.isNotEmpty) ...[
                        const _Header('Chats'),
                        for (final r in chats)
                          ListTile(
                            leading: RoomAvatar(room: r, size: 40),
                            title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: r.network == null ? null : Text(r.network!.name),
                            onTap: () => widget.onOpen(r.id, null),
                          ),
                      ],
                      if (hits.isNotEmpty) ...[
                        if (chats.isNotEmpty) const _Header('Messages'),
                        for (final h in hits) hitRow(h),
                      ],
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text("Couldn't search: $_error", style: TextStyle(color: scheme.error)),
                        ),
                      if (done && hits.isEmpty && chats.isEmpty && _error == null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
                          child: Text(
                            'No messages found',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      if (done) ...[
                        _SearchedNote(status: status, onChange: widget.onSettings),
                        if (server.isNotEmpty) ...[
                          const _Header('On the server'),
                          for (final h in server) hitRow(h),
                        ],
                        if (_serverLoading)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        else if (_serverError != null)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              "Couldn't search the server: $_serverError",
                              style: TextStyle(color: scheme.error),
                            ),
                          )
                        else if (!_askedServer || _serverNext != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                            child: Center(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.cloud_outlined),
                                label: Text(!_askedServer
                                    ? (status?.periodDays == 0
                                        ? 'Search the server too'
                                        : 'Search older messages on the server')
                                    : 'More from the server'),
                                onPressed: _searchServer,
                              ),
                            ),
                          )
                        else if (server.isEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                            child: Text(
                              'Nothing else on the server',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
}

/// What search covers, before anything is typed.
class _Hint extends StatelessWidget {
  const _Hint({required this.status, required this.scoped});
  final IndexStatus? status;
  final RoomSummary? scoped;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_rounded, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              scoped == null ? 'Search chats, messages and files' : 'Search messages and files in this chat',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant),
            ),
            if (status != null) ...[
              const SizedBox(height: 6),
              Text(
                'This device searches ${periodPhrase(status!.periodDays)}.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Under the results: what the device searched, and how to change it.
class _SearchedNote extends StatelessWidget {
  const _SearchedNote({required this.status, required this.onChange});
  final IndexStatus? status;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final since = s.sinceMs == null ? '' : ' (since ${DateFormat('d MMM y').format(DateTime.fromMillisecondsSinceEpoch(s.sinceMs!))})';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          children: [
            TextSpan(text: 'Searched ${periodPhrase(s.periodDays)} on this device$since. '),
            if (s.indexing && s.chatsDone < s.chats) TextSpan(text: 'Still indexing ${s.chats - s.chatsDone} chats. '),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap: onChange,
                child: Text('Change', style: TextStyle(fontSize: 13, color: scheme.primary, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// "Indexing chats: 45 of 132", with a thin bar.
class _IndexingLine extends StatelessWidget {
  const _IndexingLine({required this.status});
  final IndexStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: LinearProgressIndicator(
              value: status.chats == 0 ? null : status.chatsDone / status.chats,
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            status.error != null ? 'Waiting for the server' : 'Indexing ${status.chatsDone} of ${status.chats} chats',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// The matched words of a snippet in bold.
List<TextSpan> snippetSpans(String snippet, TextStyle base, TextStyle mark) {
  final spans = <TextSpan>[];
  var rest = snippet.replaceAll('\n', ' ');
  while (rest.isNotEmpty) {
    final start = rest.indexOf(_snippetStart);
    if (start < 0) {
      spans.add(TextSpan(text: rest, style: base));
      break;
    }
    if (start > 0) spans.add(TextSpan(text: rest.substring(0, start), style: base));
    final end = rest.indexOf(_snippetEnd, start);
    final stop = end < 0 ? rest.length : end;
    spans.add(TextSpan(text: rest.substring(start + 1, stop), style: mark));
    rest = end < 0 ? '' : rest.substring(end + 1);
  }
  return spans;
}

IconData? kindIcon(MessageKind kind) => switch (kind) {
      MessageKind.image => Icons.photo_outlined,
      MessageKind.video => Icons.videocam_outlined,
      MessageKind.audio => Icons.audiotrack_outlined,
      MessageKind.file => Icons.insert_drive_file_outlined,
      MessageKind.text => null,
    };

class _HitRow extends ConsumerWidget {
  const _HitRow({required this.hit, required this.room, required this.showRoom, required this.onTap});
  final SearchHit hit;
  final RoomSummary? room;

  /// Across chats: the chat's avatar and name. In one chat: the sender's.
  final bool showRoom;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final m = hit.message;
    final sender = m.isOwn ? 'You' : (m.senderName ?? m.sender);
    final r = room;
    // In a DM, the other person's name is the chat's.
    final prefix = showRoom && r != null && (r.isDm && !m.isOwn) ? null : sender;
    final base = TextStyle(fontSize: 14, height: 1.3, color: scheme.onSurfaceVariant);
    final mark = base.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700);
    final icon = kindIcon(m.kind);
    final thumb = switch (m.kind) {
      MessageKind.image => m.mxc,
      MessageKind.video => m.thumbnailMxc,
      _ => null,
    };
    final px = (44 * MediaQuery.devicePixelRatioOf(context)).round();

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showRoom && r != null) ...[RoomAvatar(room: r, size: 44), const SizedBox(width: 12)]
            else if (!showRoom) ...[MxcAvatar(name: sender, size: 36), const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          showRoom ? (r?.name ?? '') : sender,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(listTime(m.timestampMs), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      children: [
                        if (icon != null)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                            ),
                          ),
                        if (showRoom && prefix != null) TextSpan(text: '$prefix: ', style: base),
                        ...snippetSpans(hit.snippet, base, mark),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (thumb != null) ...[
              const SizedBox(width: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox.square(
                  dimension: 44,
                  child: switch (ref.watch(mediaProvider((mxc: thumb, width: px, height: px)))) {
                    AsyncData(:final value) => Image.memory(value, fit: BoxFit.cover, gaplessPlayback: true),
                    _ => ColoredBox(color: scheme.surfaceContainerHigh),
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
