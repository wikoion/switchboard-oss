import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import 'diff.dart';
import 'session.dart';

class TimelineState {
  const TimelineState({
    this.items,
    this.atStart = false,
    this.paginating = false,
    this.atEnd = true,
    this.paginatingNewer = false,
  });

  /// Oldest first. Null until the first update arrives.
  final List<TimelineItem>? items;
  final bool atStart;
  final bool paginating;

  /// The newest message is loaded. Only a timeline opened at a message
  /// (a search result) can be short of it.
  final bool atEnd;
  final bool paginatingNewer;

  TimelineState copyWith({
    List<TimelineItem>? items,
    bool? atStart,
    bool? paginating,
    bool? atEnd,
    bool? paginatingNewer,
  }) =>
      TimelineState(
        items: items ?? this.items,
        atStart: atStart ?? this.atStart,
        paginating: paginating ?? this.paginating,
        atEnd: atEnd ?? this.atEnd,
        paginatingNewer: paginatingNewer ?? this.paginatingNewer,
      );
}

final timelineProvider =
    NotifierProvider.autoDispose.family<TimelineNotifier, TimelineState, String>(
  TimelineNotifier.new,
);

/// How many messages a chat loads before it stops paging back by itself:
/// enough to fill the screen, so there is something to scroll.
const wantedMessages = 20;

/// Whether a timeline should page back by itself: it has fewer messages
/// than [wantedMessages] and the start of the chat isn't reached.
bool needsOlder(TimelineState s) {
  final items = s.items;
  if (items == null || s.atStart || s.paginating) return false;
  return items.where((i) => i.kind is TimelineItemKind_Event).length < wantedMessages;
}

class TimelineNotifier extends Notifier<TimelineState> {
  TimelineNotifier(this.roomId);

  final String roomId;
  StreamSubscription<List<TimelineDiff>>? _sub;
  Timer? _retry;
  int _failures = 0;

  @override
  TimelineState build() {
    final core = ref.watch(coreProvider);
    String? lastSeen;
    _sub = core.subscribeTimeline(roomId: roomId).listen((diffs) {
      // A reset (after a gap in sync, say) can leave only the newest
      // messages, so the start of the chat has to be found again.
      final reset = diffs.any((d) => d is TimelineDiff_Reset || d is TimelineDiff_Clear);
      final items = applyTimelineDiffs(state.items ?? const [], diffs);
      state = reset ? TimelineState(items: items, paginating: state.paginating) : state.copyWith(items: items);
      _fill();
      // The chat is open, so whatever arrives has been read.
      final last = items.isEmpty ? null : items.last.uniqueId;
      if (last != lastSeen) {
        lastSeen = last;
        unawaited(core.markRead(roomId: roomId).catchError((_) {}));
      }
    });
    ref.onDispose(() {
      _sub?.cancel();
      _retry?.cancel();
    });
    return const TimelineState();
  }

  /// Pages back until the screen has [wantedMessages]. Opened from a
  /// notification, a chat may hold only the message that arrived.
  void _fill() {
    if (needsOlder(state)) unawaited(loadOlder());
  }

  Future<void> loadOlder() async {
    if (state.paginating || state.atStart) return;
    _retry?.cancel();
    state = state.copyWith(paginating: true);
    try {
      final atStart = await ref.read(coreProvider).paginateBack(roomId: roomId, count: 30);
      if (!ref.mounted) return;
      _failures = 0;
      state = state.copyWith(atStart: atStart, paginating: false);
      // New messages arrive as diffs, which page again if still short;
      // a page of nothing but hidden events sends no diffs, so check too.
      _retry = Timer(const Duration(milliseconds: 400), _fill);
    } catch (_) {
      if (!ref.mounted) return;
      state = state.copyWith(paginating: false);
      // Often the connection isn't back yet after the app wakes; try
      // again with backoff rather than leaving the chat short.
      _failures++;
      _retry = Timer(Duration(seconds: 1 << _failures.clamp(0, 5)), _fill);
    }
  }

  /// Sends Markdown text. [mentions] are the user IDs it links to.
  Future<void> send(String body, {List<String> mentions = const []}) =>
      ref.read(coreProvider).sendText(roomId: roomId, body: body, mentions: mentions);

  /// Uploads and sends a file; photos when [mimeType] is an image.
  Future<void> sendFile(
    String path,
    String mimeType, {
    int? width,
    int? height,
    int? durationMs,
    bool isVoice = false,
  }) =>
      ref.read(coreProvider).sendFile(
            roomId: roomId,
            path: path,
            mimeType: mimeType,
            width: width,
            height: height,
            durationMs: durationMs,
            isVoice: isVoice,
          );

  Future<void> reply(String body, String eventId, {List<String> mentions = const []}) =>
      ref.read(coreProvider).sendReply(roomId: roomId, body: body, eventId: eventId, mentions: mentions);

  /// [id] is the event ID, or the transaction ID while still sending.
  Future<void> edit(String id, String body) =>
      ref.read(coreProvider).editText(roomId: roomId, id: id, body: body);

  Future<void> unsend(String id) => ref.read(coreProvider).redact(roomId: roomId, id: id);

  Future<void> retry(String transactionId) =>
      ref.read(coreProvider).retrySend(roomId: roomId, transactionId: transactionId);

  Future<void> cancel(String transactionId) =>
      ref.read(coreProvider).cancelSend(roomId: roomId, transactionId: transactionId);

  Future<void> react(String eventId, String key) =>
      ref.read(coreProvider).toggleReaction(roomId: roomId, eventId: eventId, key: key);
}

/// A chat opened at one message, such as a search result.
typedef FocusKey = ({String roomId, String eventId});

/// The messages around one event. It pages both ways; reaching the newest
/// message is the chat screen's cue to switch to the live timeline.
final focusedTimelineProvider =
    NotifierProvider.autoDispose.family<FocusedTimelineNotifier, TimelineState, FocusKey>(
  FocusedTimelineNotifier.new,
);

class FocusedTimelineNotifier extends Notifier<TimelineState> {
  FocusedTimelineNotifier(this.key);

  final FocusKey key;

  @override
  TimelineState build() {
    final core = ref.watch(coreProvider);
    final sub = core.subscribeTimelineAt(roomId: key.roomId, eventId: key.eventId).listen(
      (diffs) => state = state.copyWith(items: applyTimelineDiffs(state.items ?? const [], diffs)),
      onError: (Object _) => state = state.copyWith(items: state.items ?? const [], atStart: true),
    );
    ref.onDispose(sub.cancel);
    return const TimelineState(atEnd: false);
  }

  Future<void> loadOlder() => _page(forwards: false);

  Future<void> loadNewer() => _page(forwards: true);

  Future<void> _page({required bool forwards}) async {
    if (forwards ? (state.paginatingNewer || state.atEnd) : (state.paginating || state.atStart)) return;
    state = forwards ? state.copyWith(paginatingNewer: true) : state.copyWith(paginating: true);
    var reached = false;
    try {
      reached = await ref
          .read(coreProvider)
          .paginateFocused(roomId: key.roomId, eventId: key.eventId, forwards: forwards, count: 30);
    } catch (_) {
      // Left to the next scroll.
    }
    if (!ref.mounted) return;
    state = forwards
        ? state.copyWith(paginatingNewer: false, atEnd: reached)
        : state.copyWith(paginating: false, atStart: reached);
  }
}

/// The plain text of a message, for copying, editing and reply banners.
String? messageText(EventItem e) => switch (e.body) {
      EventBody_Text(:final body) || EventBody_Notice(:final body) || EventBody_Emote(:final body) => body,
      _ => null,
    };

/// Joined members by user ID, for "Seen" avatars and names.
final membersProvider = FutureProvider.autoDispose.family<Map<String, Member>, String>((ref, roomId) async {
  final members = await ref.watch(coreProvider).members(roomId: roomId);
  return {for (final m in members) m.userId: m};
});

/// Who else is typing in the room.
final typingProvider = StreamProvider.autoDispose.family<List<Member>, String>((ref, roomId) {
  return ref.watch(coreProvider).subscribeTyping(roomId: roomId);
});

/// Sends typing notices for a room. A plain function, so the chat screen can
/// still stop typing from dispose().
final typingNoticeProvider = Provider.autoDispose.family<void Function(bool typing), String>((ref, roomId) {
  final core = ref.watch(coreProvider);
  return (typing) => core.setTyping(roomId: roomId, typing: typing).ignore();
});

/// What the room's network supports; null for rooms that aren't bridged.
final roomFeaturesProvider = FutureProvider.autoDispose.family<RoomFeatures?, String>((ref, roomId) {
  return ref.watch(coreProvider).roomFeatures(roomId: roomId);
});

/// A bridge's latest delivery report for one of our messages.
typedef Delivery = ({BridgeStatus status, String? message});

/// Delivery reports by the event they're about. Later reports win.
Map<String, Delivery> deliveries(List<TimelineItem> items) => {
      for (final item in items)
        if (item.kind case TimelineItemKind_Event(field0: EventItem(body: EventBody_SendStatus(:final forEventId, :final status, :final message))))
          forEventId: (status: status, message: message),
    };

/// Level 1 or 2 in mautrix's capability scale; rooms without features
/// allow everything.
bool supports(RoomFeatures? f, int Function(RoomFeatures) level) => f == null || level(f) > 0;
