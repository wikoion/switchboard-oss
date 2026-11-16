import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../rust/api/types.dart';
import '../state/calls.dart';
import '../state/media.dart';
import '../state/rooms.dart';
import '../state/timeline.dart';
import '../state/views.dart';
import 'format.dart';
import 'forward.dart';
import 'image_viewer.dart';
import 'layout.dart';
import 'link_preview.dart';
import 'media_bubbles.dart';
import 'mentions.dart';
import 'rich_text.dart';
import 'save_media.dart';
import 'search_screen.dart';
import 'theme.dart';
import 'web_video.dart';
import 'widgets/avatar.dart';
import 'widgets/connection_banner.dart';

const _quickReactions = ['❤️', '👍', '😂', '😮', '😢', '🙏'];

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.roomId, this.focusEventId});
  final String roomId;

  /// Opens the chat at this message (a search result) instead of the end.
  final String? focusEventId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scroll = ScrollController();
  final _text = TextEditingController();
  final _focus = FocusNode();
  EventItem? _replyTo;
  EventItem? _editing;

  /// Mentions chosen in the composer: display name to user ID.
  final _mentions = <String, String>{};

  /// The partial name after "@" at the cursor, while choosing a mention.
  String? _mentionQuery;

  // Typing notices: sent at most every 3 s while typing, and stopped after
  // 5 s idle, on send, or on leaving. Kept from initState for dispose().
  late final void Function(bool typing) _notifyTyping;

  // Voice notes. The recorder is made on first use, so screens that never
  // record never touch the microphone plugin.
  AudioRecorder? _recorder;
  DateTime? _recordingSince;
  Timer? _recordingTick;
  DateTime? _typingSent;
  Timer? _typingIdle;

  /// Files are being dragged over the chat.
  bool _dragging = false;

  /// The message the chat was opened at, while showing the messages around
  /// it rather than the live end.
  late String? _focusEvent = widget.focusEventId;

  /// The opened-at message, lit up for a moment once scrolled to.
  late String? _highlight = widget.focusEventId;
  final _focusRowKey = GlobalKey();
  bool _scrolledToFocus = false;
  bool _seekingFocus = false;

  TimelineNotifier get _timeline => ref.read(timelineProvider(widget.roomId).notifier);

  FocusKey? get _focusKey => _focusEvent == null ? null : (roomId: widget.roomId, eventId: _focusEvent!);

  @override
  void initState() {
    super.initState();
    _notifyTyping = ref.read(typingNoticeProvider(widget.roomId));
    _text.addListener(_onComposerChanged);
    _scroll.addListener(() {
      final p = _scroll.position;
      final focus = _focusKey;
      // The list is reversed, so the far end is the oldest message.
      if (p.pixels > p.maxScrollExtent - 400) {
        if (focus == null) {
          _timeline.loadOlder();
        } else {
          ref.read(focusedTimelineProvider(focus).notifier).loadOlder();
        }
      }
      if (focus != null && p.pixels < 400) ref.read(focusedTimelineProvider(focus).notifier).loadNewer();
    });
  }

  @override
  void didUpdateWidget(ChatScreen old) {
    super.didUpdateWidget(old);
    // Another search result in the chat already open.
    if (widget.focusEventId != old.focusEventId && widget.focusEventId != null) {
      setState(() {
        _focusEvent = widget.focusEventId;
        _highlight = widget.focusEventId;
        _scrolledToFocus = false;
      });
    }
  }

  /// Back to the newest messages, from a message the chat was opened at.
  void _goLive() {
    if (_focusEvent == null) return;
    setState(() {
      _focusEvent = null;
      _highlight = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  /// Scrolls the opened-at message into view. It may not be built yet if
  /// it's further up than the list builds ahead, so step up and look again.
  void _scrollToFocus([int attempt = 0]) {
    if (!mounted || _scrolledToFocus || (attempt == 0 && _seekingFocus)) return;
    _seekingFocus = true;
    final row = _focusRowKey.currentContext;
    if (row != null) {
      _scrolledToFocus = true;
      _seekingFocus = false;
      Scrollable.ensureVisible(row, alignment: 0.4, duration: const Duration(milliseconds: 200));
      Timer(const Duration(milliseconds: 2500), () {
        if (mounted) setState(() => _highlight = null);
      });
      return;
    }
    if (attempt > 10 || !_scroll.hasClients) {
      _seekingFocus = false;
      return;
    }
    final p = _scroll.position;
    _scroll.jumpTo((p.pixels + p.viewportDimension * 0.8).clamp(0.0, p.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus(attempt + 1));
  }

  void _onComposerChanged() {
    final query = mentionQuery(_text.text, _text.selection.baseOffset);
    if (query != _mentionQuery) setState(() => _mentionQuery = query);
    final hasText = _text.text.trim().isNotEmpty;
    _typingIdle?.cancel();
    if (!hasText) {
      _stopTyping();
      return;
    }
    final features = ref.read(roomFeaturesProvider(widget.roomId)).value;
    if (features != null && !features.typingNotifications) return;
    final now = DateTime.now();
    if (_typingSent == null || now.difference(_typingSent!) > const Duration(seconds: 3)) {
      _typingSent = now;
      _notifyTyping(true);
    }
    _typingIdle = Timer(const Duration(seconds: 5), _stopTyping);
  }

  void _stopTyping() {
    _typingIdle?.cancel();
    if (_typingSent == null) return;
    _typingSent = null;
    _notifyTyping(false);
  }

  @override
  void dispose() {
    _recordingTick?.cancel();
    _recorder?.dispose();
    _stopTyping();
    _scroll.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startReply(EventItem e) {
    setState(() {
      _replyTo = e;
      if (_editing != null) _text.clear();
      _editing = null;
    });
    _focus.requestFocus();
  }

  void _startEdit(EventItem e) {
    setState(() {
      _editing = e;
      _replyTo = null;
    });
    _text.text = messageText(e) ?? '';
    _focus.requestFocus();
  }

  void _clearCompose() {
    if (_editing != null) _text.clear();
    setState(() {
      _replyTo = null;
      _editing = null;
    });
  }

  Future<void> _send(String body) {
    _stopTyping();
    // What's sent shows at the end.
    _goLive();
    final editing = _editing;
    final replyTo = _replyTo;
    final mentioned = applyMentions(body, _mentions);
    setState(() {
      _editing = null;
      _replyTo = null;
      _mentions.clear();
      _mentionQuery = null;
    });
    if (editing != null) return _timeline.edit(editing.eventId ?? editing.transactionId!, mentioned.markdown);
    if (replyTo?.eventId != null) {
      return _timeline.reply(mentioned.markdown, replyTo!.eventId!, mentions: mentioned.userIds);
    }
    return _timeline.send(mentioned.markdown, mentions: mentioned.userIds);
  }

  void _chooseMention(Member m) {
    final name = m.name ?? m.userId;
    final (text, cursor) = insertMention(_text.text, _text.selection.baseOffset, name);
    _mentions[name] = m.userId;
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
    );
    setState(() => _mentionQuery = null);
  }

  Future<void> _attach() async {
    final features = ref.read(roomFeaturesProvider(widget.roomId)).value;
    final photos = features == null || features.images;
    final video = features == null || features.video;
    final files = features == null || features.files;
    final picker = ImagePicker();
    // No camera on Linux.
    final camera = picker.supportsImageSource(ImageSource.camera);
    final choice = await showModalBottomSheet<_Attach>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (photos) ...[
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Photo library'),
                onTap: () => Navigator.pop(sheet, _Attach.photos),
              ),
              if (camera)
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Camera'),
                  onTap: () => Navigator.pop(sheet, _Attach.camera),
                ),
            ],
            if (video)
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: const Text('Video'),
                onTap: () => Navigator.pop(sheet, _Attach.video),
              ),
            if (files)
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: const Text('File'),
                onTap: () => Navigator.pop(sheet, _Attach.file),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    switch (choice) {
      case _Attach.photos || _Attach.camera:
        final images = choice == _Attach.camera
            ? [?await picker.pickImage(source: ImageSource.camera, imageQuality: 90)]
            : await picker.pickMultiImage(imageQuality: 90);
        for (final f in images) {
          await _run(() async {
            final bytes = await f.readAsBytes();
            final image = await decodeImageFromList(bytes);
            await _timeline.sendFile(f.path, f.mimeType ?? mimeFor(f.path), width: image.width, height: image.height);
            image.dispose();
          }, "Couldn't send photo");
        }
      case _Attach.video:
        final f = await picker.pickVideo(source: ImageSource.gallery);
        if (f != null) {
          await _run(() => _timeline.sendFile(f.path, f.mimeType ?? mimeFor(f.path)), "Couldn't send video");
        }
      case _Attach.file:
        final picked = await FilePicker.pickFiles();
        for (final f in picked) {
          final path = f.path;
          if (path != null) await _run(() => _timeline.sendFile(path, mimeFor(path)), "Couldn't send file");
        }
    }
  }

  /// Files dropped on the chat or pasted: confirm, then send each one.
  Future<void> _sendPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    final features = ref.read(roomFeaturesProvider(widget.roomId)).value;
    if (features != null && !features.images && !features.video && !features.files) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("This chat doesn't take files")));
      return;
    }
    final names = [for (final p in paths) p.split('/').last];
    final single = paths.length == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(single ? 'Send ${names.first}?' : 'Send ${paths.length} files?'),
        content: single && mimeFor(paths.first).startsWith('image/')
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240, maxWidth: 360),
                child: Image.file(File(paths.first), fit: BoxFit.contain),
              )
            : single
                ? null
                : Text(names.join('\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true) return;
    for (final path in paths) {
      final mime = mimeFor(path);
      if (mime.startsWith('image/')) {
        await _run(() async {
          final image = await decodeImageFromList(await File(path).readAsBytes());
          await _timeline.sendFile(path, mime, width: image.width, height: image.height);
          image.dispose();
        }, "Couldn't send photo");
      } else {
        await _run(() => _timeline.sendFile(path, mime), "Couldn't send file");
      }
    }
  }

  /// Ctrl+V: files copied in a file manager, then an image, then text.
  Future<void> _paste() async {
    var paths = const <String>[];
    try {
      paths = await Pasteboard.files();
      if (paths.isEmpty) {
        final image = await Pasteboard.image;
        if (image != null) {
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/pasted-${DateTime.now().millisecondsSinceEpoch}.png');
          await file.writeAsBytes(image, flush: true);
          paths = [file.path];
        }
      }
    } catch (_) {
      // Text still pastes if the clipboard plugin fails.
    }
    if (paths.isNotEmpty) return _sendPaths(paths);
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) return;
    final v = _text.value;
    final at = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    _text.value = TextEditingValue(
      text: v.text.replaceRange(at.start, at.end, text),
      selection: TextSelection.collapsed(offset: at.start + text.length),
    );
  }

  Future<void> _startVoice() async {
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Allow microphone access in Settings to record voice notes')));
      }
      return;
    }
    HapticFeedback.mediumImpact();
    _stopTyping();
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
    await recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1),
      path: path,
    );
    setState(() => _recordingSince = DateTime.now());
    _recordingTick = Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {}));
  }

  /// Stops recording; sends the note unless cancelled or under half a second.
  Future<void> _finishVoice({required bool send}) async {
    final since = _recordingSince;
    _recordingTick?.cancel();
    setState(() => _recordingSince = null);
    final path = await _recorder?.stop();
    if (path == null || since == null) return;
    final ms = DateTime.now().difference(since).inMilliseconds;
    if (!send || ms < 500) {
      await File(path).delete().catchError((_) => File(path));
      return;
    }
    await _run(() => _timeline.sendFile(path, 'audio/mp4', durationMs: ms, isVoice: true), "Couldn't send voice note");
  }

  Future<void> _run(Future<void> Function() action, String failed) async {
    try {
      await action();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$failed: $e')));
    }
  }

  /// What can be done with a message, for the long-press sheet and the
  /// desktop menu. Send again comes first and the rest follow the
  /// reactions.
  ({List<String> reactions, _Action? sendAgain, List<_Action> rest}) _messageActions(EventItem e, Delivery? delivery) {
    final text = messageText(e);
    final failed = e.sendState is SendState_Failed;
    final id = e.eventId ?? e.transactionId;
    final features = ref.read(roomFeaturesProvider(widget.roomId)).value;
    final undelivered =
        delivery != null && (delivery.status == BridgeStatus.retriable || delivery.status == BridgeStatus.failed);
    final reactions = features == null || features.allowedReactions.isEmpty
        ? _quickReactions
        : [
            for (final r in _quickReactions)
              if (features.allowedReactions.contains(r)) r,
          ];
    return (
      reactions: e.eventId != null && supports(features, (f) => f.reaction) ? reactions : const [],
      sendAgain: undelivered && text != null
          ? _Action(Icons.send_rounded, 'Send again', () => _run(() => _timeline.send(text), "Couldn't send"))
          : null,
      rest: [
        if (failed && e.transactionId != null) ...[
          _Action(Icons.refresh_rounded, 'Try again', () => _run(() => _timeline.retry(e.transactionId!), "Couldn't retry")),
          _Action(Icons.delete_outline_rounded, "Don't send",
              () => _run(() => _timeline.cancel(e.transactionId!), "Couldn't cancel")),
        ],
        if (e.canReply && e.eventId != null && supports(features, (f) => f.reply))
          _Action(Icons.reply_rounded, 'Reply', () => _startReply(e)),
        if (e.isOwn && e.canEdit && text != null && supports(features, (f) => f.edit))
          _Action(Icons.edit_outlined, 'Edit', () => _startEdit(e)),
        if (text != null) _Action(Icons.copy_rounded, 'Copy', () => Clipboard.setData(ClipboardData(text: text))),
        if (_savable(e) case (final mxc, final name, final video)) ...[
          _Action(saveMediaIcon, saveMediaLabel,
              () => saveMedia(context, ref, mxc: mxc, name: name, mimetype: _mimetype(e), video: video)),
          if (canShareMedia)
            _Action(shareMediaIcon, 'Share',
                () => shareMedia(context, ref, mxc: mxc, name: name, mimetype: _mimetype(e), video: video)),
          if (e.eventId case final eventId?)
            _Action(forwardIcon, 'Forward', () => forwardMessage(context, ref, roomId: widget.roomId, eventId: eventId)),
        ],
        if (e.isOwn && id != null && !failed && e.body is! EventBody_Redacted && supports(features, (f) => f.delete))
          _Action(Icons.undo_rounded, 'Unsend', () => _run(() => _timeline.unsend(id), "Couldn't unsend"),
              destructive: true),
      ],
    );
  }

  void _react(EventItem e, String key) => _run(() => _timeline.react(e.eventId!, key), "Couldn't react");

  /// A photo or video's source, name and kind, for saving, sharing and
  /// forwarding it.
  static (String, String, bool)? _savable(EventItem e) => switch (e.body) {
        EventBody_Image(:final mxc?, :final body) => (mxc, body, false),
        EventBody_Video(:final mxc?, :final body) => (mxc, body, true),
        _ => null,
      };

  static String? _mimetype(EventItem e) => switch (e.body) {
        EventBody_Video(:final mimetype) => mimetype,
        _ => null,
      };

  /// The long-press sheet, or on desktop a menu at [at].
  void _showActions(EventItem e, {Delivery? delivery, Offset? at}) {
    if (at != null) {
      _showActionMenu(e, delivery, at);
      return;
    }
    HapticFeedback.mediumImpact();
    final (:reactions, :sendAgain, :rest) = _messageActions(e, delivery);
    final undelivered =
        delivery != null && (delivery.status == BridgeStatus.retriable || delivery.status == BridgeStatus.failed);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Tall enough for every action; scrolls on small screens.
      isScrollControlled: true,
      builder: (sheet) {
        void act(VoidCallback f) {
          Navigator.pop(sheet);
          f();
        }

        final error = Theme.of(context).colorScheme.error;
        Widget tile(_Action a) => ListTile(
              leading: Icon(a.icon, color: a.destructive ? error : null),
              title: Text(a.label, style: a.destructive ? TextStyle(color: error) : null),
              onTap: () => act(a.onTap),
            );

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (undelivered)
                  ListTile(
                    leading: Icon(Icons.error_outline_rounded, color: error),
                    title: const Text('Not delivered'),
                    subtitle: delivery.message == null ? null : Text(delivery.message!),
                  ),
                if (sendAgain != null) tile(sendAgain),
                if (reactions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (final key in reactions)
                          InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: () => act(() => _react(e, key)),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(key, style: const TextStyle(fontSize: 28)),
                            ),
                          ),
                      ],
                    ),
                  ),
                for (final a in rest) tile(a),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The right-click menu: a row of reactions, then the actions.
  Future<void> _showActionMenu(EventItem e, Delivery? delivery, Offset at) async {
    final (:reactions, :sendAgain, :rest) = _messageActions(e, delivery);
    final actions = [?sendAgain, ...rest];
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final p = overlay.globalToLocal(at);
    final error = Theme.of(context).colorScheme.error;
    final chosen = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromLTRB(p.dx, p.dy, overlay.size.width - p.dx, overlay.size.height - p.dy),
      items: [
        if (reactions.isNotEmpty)
          _ReactionMenuRow(reactions: reactions, onReact: (key) => () => _react(e, key)),
        for (final a in actions)
          PopupMenuItem(
            value: a.onTap,
            child: Row(
              children: [
                Icon(a.icon, size: 20, color: a.destructive ? error : null),
                const SizedBox(width: 12),
                Text(a.label, style: a.destructive ? TextStyle(color: error) : null),
              ],
            ),
          ),
      ],
    );
    chosen?.call();
  }

  /// The newest message of yours that can be edited, for ↑ in the composer.
  void _editLast() {
    final features = ref.read(roomFeaturesProvider(widget.roomId)).value;
    if (!supports(features, (f) => f.edit)) return;
    final items = ref.read(timelineProvider(widget.roomId)).items ?? const [];
    for (final item in items.reversed) {
      if (item.kind case TimelineItemKind_Event(field0: final e)
          when e.isOwn && e.canEdit && e.eventId != null && messageText(e) != null) {
        _startEdit(e);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = ref.watch(roomSummaryProvider(widget.roomId));
    final focus = _focusKey;
    final timeline =
        focus == null ? ref.watch(timelineProvider(widget.roomId)) : ref.watch(focusedTimelineProvider(focus));
    if (focus != null) {
      // Paged down to the newest message: carry on live.
      ref.listen(focusedTimelineProvider(focus), (_, next) {
        if (next.atEnd) _goLive();
      });
      if (timeline.items != null && !_scrolledToFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
      }
    }
    final items = timeline.items;
    final isGroup = room != null && !room.isDm;
    final scheme = Theme.of(context).colorScheme;
    final features = ref.watch(roomFeaturesProvider(widget.roomId)).value;
    final canAttach = features == null || features.images || features.video || features.files;
    final supportsVoice = features == null || features.voice || features.audio;
    final reports = items == null ? const <String, Delivery>{} : deliveries(items);

    final beside = panesOf(context) != Panes.one;

    return Scaffold(
      appBar: AppBar(
        // Beside the list there is nothing to go back to.
        automaticallyImplyLeading: !beside,
        titleSpacing: beside ? 16 : 0,
        actions: [
          if (room != null && canCall(room) && ref.watch(callServiceProvider).value != null)
            for (final video in [true, false])
              IconButton(
                tooltip: video ? 'Video call' : 'Call',
                icon: Icon(video ? Icons.videocam_outlined : Icons.call_outlined),
                // One call at a time.
                onPressed: ref.watch(callProvider) == null
                    ? () => ref.read(callProvider.notifier).place(room.id, video: video).catchError((Object e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't call: $e")));
                          }
                        })
                    : null,
              ),
          if (room != null)
            IconButton(
              tooltip: room.isFavourite ? 'Remove from Favourites' : 'Favourite',
              icon: Icon(
                room.isFavourite ? Icons.star_rounded : Icons.star_border_rounded,
                color: room.isFavourite ? favouriteColor : null,
              ),
              onPressed: () => setFavourite(ref, room, !room.isFavourite).catchError((Object e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't update favourites: $e")));
                }
              }),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (v) => v == 'search' ? openSearch(context, roomId: widget.roomId) : _openMedia(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'search',
                child: ListTile(
                  leading: const Icon(Icons.search_rounded),
                  title: const Text('Search in chat'),
                  trailing: isDesktop ? Text(primaryLabel('F')) : null,
                ),
              ),
              const PopupMenuItem(
                value: 'media',
                child: ListTile(leading: Icon(Icons.perm_media_outlined), title: Text('Media, files and links')),
              ),
            ],
          ),
        ],
        title: room == null
            ? const SizedBox.shrink()
            // As in other chat apps, the header opens what's been shared.
            : GestureDetector(
                onTap: _openMedia,
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: [
                    RoomAvatar(room: room, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            room.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                          ),
                          if (room.network != null)
                            Text(
                              [
                                room.network!.name,
                                if (ref.watch(roomAccountProvider(widget.roomId)) case final login?)
                                  login.handle ?? login.name,
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
      body: _dropTarget(Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: Stack(
              children: [
                items == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        itemCount: items.length + 1,
                        itemBuilder: (context, i) {
                          if (i == items.length) {
                            return timeline.paginating
                                ? const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                                  )
                                : const SizedBox(height: 8);
                          }
                          final index = items.length - 1 - i;
                          return _buildItem(items, index, isGroup, reports, features);
                        },
                      ),
                if (focus != null)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FloatingActionButton.small(
                      heroTag: null,
                      tooltip: 'Jump to latest',
                      onPressed: _goLive,
                      child: const Icon(Icons.keyboard_double_arrow_down_rounded),
                    ),
                  ),
              ],
            ),
          ),
          if (_mentionQuery != null)
            _MentionSuggestions(roomId: widget.roomId, query: _mentionQuery!, onChoose: _chooseMention),
          _TypingRow(roomId: widget.roomId),
          _Composer(
            controller: _text,
            focusNode: _focus,
            banner: _composeBanner(),
            onCancelBanner: _clearCompose,
            onSend: _send,
            onAttach: canAttach ? _attach : null,
            onMic: supportsVoice ? _startVoice : null,
            onEditLast: _editLast,
            onPaste: _paste,
            recording: _recordingSince == null ? null : DateTime.now().difference(_recordingSince!),
            onRecordingDone: (send) => _finishVoice(send: send),
          ),
        ],
      )),
    );
  }

  void _openMedia() => openPage(context, '/room/${Uri.encodeComponent(widget.roomId)}/media');

  /// On desktop, files dropped on the chat are sent after a confirm.
  Widget _dropTarget(Widget body) {
    if (!isDesktop) return body;
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        setState(() => _dragging = false);
        _sendPaths([for (final f in d.files) f.path]);
      },
      child: Stack(
        children: [
          body,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.08),
                    border: Border.all(color: scheme.primary, width: 2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: Text('Drop to send', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget? _composeBanner() {
    final e = _editing ?? _replyTo;
    if (e == null) return null;
    final title = _editing != null
        ? 'Editing message'
        : 'Replying to ${e.isOwn ? 'yourself' : (e.senderName ?? e.sender)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (_replyTo != null)
          Text(
            messageText(e) ?? 'Message',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _buildItem(
    List<TimelineItem> items,
    int index,
    bool isGroup,
    Map<String, Delivery> reports,
    RoomFeatures? features,
  ) {
    final item = items[index];
    switch (item.kind) {
      case TimelineItemKind_DateDivider(:final timestampMs):
        return _DayDivider(label: dayLabel(timestampMs));
      case TimelineItemKind_ReadMarker():
      case TimelineItemKind_TimelineStart():
        return const SizedBox.shrink();
      case TimelineItemKind_Event(field0: EventItem(body: EventBody_SendStatus())):
        return const SizedBox.shrink();
      case TimelineItemKind_Event(field0: final event):
        final older = _neighbour(items, index, -1);
        final newer = _neighbour(items, index, 1);
        final delivery = event.eventId == null ? null : reports[event.eventId];
        bool sameGroup(EventItem? other) =>
            other != null &&
            other.sender == event.sender &&
            (other.timestampMs - event.timestampMs).abs() < 5 * 60 * 1000;
        final members = ref.watch(membersProvider(widget.roomId)).value ?? const {};
        final row = _MessageRow(
          key: ValueKey(item.uniqueId),
          roomId: widget.roomId,
          event: event,
          seenBy: event.isOwn ? [for (final id in event.readBy) members[id] ?? Member(userId: id)] : const [],
          showSender: isGroup && !event.isOwn && !sameGroup(older),
          showAvatar: isGroup && !event.isOwn && !sameGroup(newer),
          isGroup: isGroup,
          firstInGroup: !sameGroup(older),
          lastInGroup: !sameGroup(newer),
          onReact: (key) {
            final id = event.eventId;
            if (id != null) _run(() => _timeline.react(id, key), "Couldn't react");
          },
          delivery: delivery,
          onActions: ([at]) => _showActions(event, delivery: delivery, at: at),
          onSwipeReply: event.canReply && event.eventId != null && supports(features, (f) => f.reply)
              ? () => _startReply(event)
              : null,
        );
        if (_focusEvent == null || event.eventId != _focusEvent) return row;
        final lit = _highlight == event.eventId;
        return AnimatedContainer(
          key: _focusRowKey,
          duration: const Duration(milliseconds: 600),
          decoration: BoxDecoration(
            color: lit ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: row,
        );
    }
  }

  /// The nearest shown message in direction [step], skipping hidden items;
  /// a day divider ends the search.
  static EventItem? _neighbour(List<TimelineItem> items, int index, int step) {
    for (var i = index + step; i >= 0 && i < items.length; i += step) {
      switch (items[i].kind) {
        case TimelineItemKind_Event(field0: EventItem(body: EventBody_SendStatus())):
        case TimelineItemKind_ReadMarker():
          continue;
        case TimelineItemKind_Event(field0: final e):
          return e;
        default:
          return null;
      }
    }
    return null;
  }
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Text(
          label,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    super.key,
    required this.roomId,
    required this.event,
    required this.showSender,
    required this.showAvatar,
    required this.isGroup,
    required this.firstInGroup,
    required this.lastInGroup,
    required this.onReact,
    required this.onActions,
    this.onSwipeReply,
    this.seenBy = const [],
    this.delivery,
  });

  final String roomId;
  final EventItem event;
  final bool showSender;
  final bool showAvatar;
  final bool isGroup;
  final bool firstInGroup;
  final bool lastInGroup;
  final void Function(String key) onReact;

  /// Opens the message's actions: a sheet, or on desktop a menu at [at].
  final void Function([Offset? at]) onActions;

  /// Others whose read receipt is on this message of yours.
  final List<Member> seenBy;

  /// The bridge's report on delivering this message to the network.
  final Delivery? delivery;

  bool get _undelivered => delivery?.status == BridgeStatus.retriable || delivery?.status == BridgeStatus.failed;

  /// Swipe right to reply. Null where replies aren't possible.
  final VoidCallback? onSwipeReply;

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return _withSwipe(context, _row(context, maxBubble: MediaQuery.sizeOf(context).width * 0.75));
    // Desktop: bubbles sized to the conversation pane, right-click for
    // actions, and Reply and More on hover.
    return LayoutBuilder(
      builder: (context, c) => _Hover(
        builder: (context, hovering) => _row(
          context,
          maxBubble: math.min(c.maxWidth * 0.7, 640),
          tools: Visibility(
            visible: hovering,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: _MessageTools(onReply: onSwipeReply, onMore: onActions),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, {required double maxBubble, Widget? tools}) {
    final scheme = Theme.of(context).colorScheme;
    final own = event.isOwn;
    final name = event.senderName ?? event.sender;
    const r = Radius.circular(18);
    const tight = Radius.circular(6);
    final radius = BorderRadius.only(
      topLeft: !own && !firstInGroup ? tight : r,
      bottomLeft: !own && !lastInGroup ? tight : r,
      topRight: own && !firstInGroup ? tight : r,
      bottomRight: own && !lastInGroup ? tight : r,
    );
    final isMedia = event.body is EventBody_Image || event.body is EventBody_Sticker || event.body is EventBody_Video;

    final bubble = GestureDetector(
      onLongPress: onActions,
      onSecondaryTapUp: isDesktop ? (d) => onActions(d.globalPosition) : null,
      // A failed message opens its retry options on tap.
      onTapUp: event.sendState is SendState_Failed || _undelivered
          ? (d) => onActions(isDesktop ? d.globalPosition : null)
          : null,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxBubble),
        padding: isMedia ? const EdgeInsets.all(3) : const EdgeInsets.fromLTRB(12, 8, 12, 7),
        decoration: BoxDecoration(color: own ? scheme.primary : scheme.surfaceContainer, borderRadius: radius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (event.replyTo != null) _ReplyQuote(reply: event.replyTo!, own: own),
            if (isMedia)
              // Time and ticks sit over the photo's corner.
              Stack(
                children: [
                  _Body(roomId: roomId, event: event, own: own),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: _Footer(event: event, own: own, overlay: true, delivery: delivery),
                  ),
                ],
              )
            else ...[
              _Body(roomId: roomId, event: event, own: own),
              const SizedBox(height: 2),
              _Footer(event: event, own: own, overlay: false, delivery: delivery),
            ],
          ],
        ),
      ),
    );

    final row = Padding(
      padding: EdgeInsets.only(top: firstInGroup ? 8 : 2),
      child: Column(
        crossAxisAlignment: own ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showSender)
            Padding(
              padding: const EdgeInsets.only(left: 52, bottom: 3),
              child: Text(
                name,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
              ),
            ),
          Row(
            mainAxisAlignment: own ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (isGroup && !own)
                SizedBox(
                  width: 42,
                  child: showAvatar
                      ? Align(
                          alignment: Alignment.bottomLeft,
                          child: MxcAvatar(name: name, mxc: event.senderAvatarMxc, size: 32),
                        )
                      : null,
                ),
              if (own && tools != null) tools,
              Flexible(child: bubble),
              if (!own && tools != null) tools,
            ],
          ),
          if (event.reactions.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: 4, left: isGroup && !own ? 42 : 0),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final reaction in event.reactions)
                    _ReactionChip(reaction: reaction, onTap: () => onReact(reaction.key)),
                ],
              ),
            ),
          if (seenBy.isNotEmpty) _Seen(members: seenBy, group: isGroup),
        ],
      ),
    );
    return row;
  }

  Widget _withSwipe(BuildContext context, Widget row) {
    final scheme = Theme.of(context).colorScheme;
    final swipe = onSwipeReply;
    if (swipe == null) return row;
    return Dismissible(
      key: ValueKey('swipe-${event.eventId}'),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: 0.2},
      confirmDismiss: (_) async {
        HapticFeedback.selectionClick();
        swipe();
        return false;
      },
      background: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Icon(Icons.reply_rounded, color: scheme.onSurfaceVariant),
        ),
      ),
      child: row,
    );
  }
}

/// Tracks whether the mouse is over [builder]'s child.
class _Hover extends StatefulWidget {
  const _Hover({required this.builder});
  final Widget Function(BuildContext context, bool hovering) builder;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: widget.builder(context, _hovering),
      );
}

/// Reply and More beside a message on hover.
class _MessageTools extends StatelessWidget {
  const _MessageTools({required this.onReply, required this.onMore});
  final VoidCallback? onReply;
  final void Function([Offset? at]) onMore;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onReply != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: 'Reply',
              icon: Icon(Icons.reply_rounded, color: color),
              onPressed: onReply,
            ),
          Builder(
            builder: (button) => IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: 'More',
              icon: Icon(Icons.more_horiz_rounded, color: color),
              onPressed: () {
                final box = button.findRenderObject()! as RenderBox;
                onMore(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The reactions along the top of the desktop message menu.
class _ReactionMenuRow extends PopupMenuEntry<VoidCallback> {
  const _ReactionMenuRow({required this.reactions, required this.onReact});
  final List<String> reactions;
  final VoidCallback Function(String key) onReact;

  @override
  double get height => 48;

  @override
  bool represents(VoidCallback? value) => false;

  @override
  State<_ReactionMenuRow> createState() => _ReactionMenuRowState();
}

class _ReactionMenuRowState extends State<_ReactionMenuRow> {
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final key in widget.reactions)
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => Navigator.pop(context, widget.onReact(key)),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(key, style: const TextStyle(fontSize: 22)),
                ),
              ),
          ],
        ),
      );
}

/// One thing to do with a message.
class _Action {
  const _Action(this.icon, this.label, this.onTap, {this.destructive = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;
}

class _Body extends ConsumerWidget {
  /// The bridge's preview, else Synapse's for the first link in the text.
  LinkPreview? _preview(WidgetRef ref, String body) {
    if (event.linkPreview case final p?) return p;
    final link = linkify(body).where((r) => r.link != null).firstOrNull?.link;
    if (link == null) return null;
    return ref.watch(linkPreviewProvider(link)).value;
  }

  const _Body({required this.roomId, required this.event, required this.own});
  final String roomId;
  final EventItem event;
  final bool own;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final color = own ? Colors.white : scheme.onSurface;
    final muted = own ? Colors.white70 : scheme.onSurfaceVariant;
    final style = TextStyle(fontSize: 16, height: 1.3, color: color);
    final italic = style.copyWith(fontStyle: FontStyle.italic, color: muted);

    Widget withIcon(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: muted),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: style)),
      ],
    );

    return switch (event.body) {
      EventBody_Text(:final body, :final formattedHtml) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          MessageText(body: body, html: formattedHtml, style: style, own: own),
          if (_preview(ref, body) case final preview?) LinkPreviewCard(preview: preview, own: own),
        ],
      ),
      EventBody_Notice(:final body) => MessageText(
        body: body,
        style: style.copyWith(color: muted),
        own: own,
      ),
      EventBody_Emote(:final body) => Text('* ${event.senderName ?? ''} $body', style: italic),
      EventBody_Image(:final mxc, :final width, :final height, :final body) when event.unresolvedMedia != null =>
        _UnresolvedMedia(
          roomId: roomId,
          event: event,
          builder: (onTap) => _Image(mxc: mxc, width: width, height: height, alt: body, onTap: onTap),
        ),
      EventBody_Image(:final mxc, :final width, :final height, :final body) => _Image(
        mxc: mxc,
        width: width,
        height: height,
        alt: body,
        roomId: roomId,
        eventId: event.eventId,
      ),
      EventBody_Sticker(:final mxc, :final body) => _Image(mxc: mxc, width: 160, height: 160, alt: body),
      EventBody_Video(:final body, :final mxc, :final thumbnailMxc, :final durationMs, :final width, :final height) =>
        VideoBubble(
          eventId: event.eventId,
          name: body,
          mxc: mxc,
          thumbnailMxc: thumbnailMxc,
          durationMs: durationMs,
          width: width,
          height: height,
        ),
      EventBody_Audio(:final body, :final mxc, :final durationMs, :final isVoice) => AudioBubble(
        name: body,
        mxc: mxc,
        durationMs: durationMs,
        isVoice: isVoice,
        own: own,
      ),
      EventBody_File(:final name, :final mxc, :final mimetype, :final size) => FileBubble(
        name: name,
        mxc: mxc,
        mimetype: mimetype,
        size: size,
        own: own,
      ),
      EventBody_Location(:final body) => withIcon(Icons.place_rounded, body),
      EventBody_Poll(:final question) => withIcon(Icons.poll_rounded, question),
      EventBody_Redacted() => Text('Message deleted', style: italic),
      EventBody_Encrypted() => Text('Encrypted message', style: italic),
      EventBody_State(:final text) => Text(text, style: italic),
      EventBody_Unsupported(:final description) => Text('Unsupported message: $description', style: italic),
      EventBody_SendStatus() => const SizedBox.shrink(),
    };
  }
}

class _Image extends ConsumerWidget {
  const _Image({
    required this.mxc,
    required this.width,
    required this.height,
    required this.alt,
    this.onTap,
    this.roomId,
    this.eventId,
  });
  final String? mxc;
  final int? width;
  final int? height;
  final String alt;

  /// The photo's message, for forwarding it from the full-screen view.
  final String? roomId;
  final String? eventId;

  /// Replaces opening the photo full screen.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maxW = MediaQuery.sizeOf(context).width * 0.75 - 6;
    final aspect = (width != null && height != null && height! > 0) ? width! / height! : 4 / 3;
    final w = maxW.clamp(80.0, 280.0);
    final h = (w / aspect).clamp(80.0, 360.0);
    final px = (w * MediaQuery.devicePixelRatioOf(context)).round();
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(width: w, height: h, color: scheme.surfaceContainerHigh);
    final uri = mxc;
    if (uri == null) return placeholder;
    final thumb = (mxc: uri, width: px, height: (px / aspect).round());
    final bytes = ref.watch(mediaProvider(thumb));
    return GestureDetector(
      onTap: onTap ??
          () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (_) =>
                      ImageViewer(mxc: uri, thumbnail: thumb, alt: alt, roomId: roomId, eventId: eventId),
                ),
              ),
      child: Hero(
        tag: uri,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: switch (bytes) {
            AsyncData(:final value) => Image.memory(
              value,
              width: w,
              height: h,
              fit: BoxFit.cover,
              semanticLabel: alt,
              gaplessPlayback: true,
            ),
            _ => placeholder,
          },
        ),
      ),
    );
  }
}

/// A stand-in the bridge can swap for the real media, such as an Instagram
/// reel sent as its still. Tapping asks the bridge to fetch it; the message
/// then turns into a video, which opens by itself.
class _UnresolvedMedia extends ConsumerStatefulWidget {
  const _UnresolvedMedia({required this.roomId, required this.event, required this.builder});
  final String roomId;
  final EventItem event;
  final Widget Function(VoidCallback onTap) builder;

  @override
  ConsumerState<_UnresolvedMedia> createState() => _UnresolvedMediaState();
}

class _UnresolvedMediaState extends ConsumerState<_UnresolvedMedia> {
  bool _busy = false;

  Future<void> _resolve() async {
    if (_busy) return;
    setState(() => _busy = true);
    final eventId = widget.event.eventId;
    if (eventId != null) ref.read(autoplayProvider.notifier).add(eventId);
    try {
      await resolveUnresolvedMedia(ref, widget.roomId, widget.event);
    } catch (e) {
      if (eventId != null) ref.read(autoplayProvider.notifier).take(eventId);
      if (!mounted) return;
      final external = Uri.tryParse(widget.event.externalUrl ?? '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Couldn't load the video: $e"),
        action: external == null
            ? null
            : SnackBarAction(label: 'Open', onPressed: () => launchUrl(external, mode: LaunchMode.externalApplication)),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        widget.builder(_resolve),
        IgnorePointer(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
            child: _busy
                ? const SizedBox.square(
                    dimension: 32,
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                    ),
                  )
                : const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
          ),
        ),
      ],
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.reply, required this.own});
  final ReplyPreview reply;
  final bool own;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bar = own ? Colors.white70 : scheme.primary;
    final text = own ? Colors.white : scheme.onSurface;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: own ? Colors.white.withValues(alpha: 0.15) : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: bar, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            reply.senderName ?? 'Reply',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: text),
          ),
          Text(
            reply.text ?? '…',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: text),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.event, required this.own, required this.overlay, this.delivery});
  final EventItem event;
  final bool own;
  final bool overlay;
  final Delivery? delivery;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = overlay ? Colors.white : (own ? Colors.white70 : scheme.onSurfaceVariant);
    // The server's answer first, then the bridge's report on the network.
    final failed =
        event.sendState is SendState_Failed ||
        delivery?.status == BridgeStatus.retriable ||
        delivery?.status == BridgeStatus.failed;
    final icon = failed
        ? Icons.error_rounded
        : switch (event.sendState) {
            SendState_Sending() => Icons.schedule_rounded,
            _ when delivery?.status == BridgeStatus.pending => Icons.schedule_rounded,
            _ => event.readBy.isNotEmpty ? Icons.done_all_rounded : Icons.done_rounded,
          };
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (event.isEdited) Text('edited · ', style: TextStyle(fontSize: 11, color: color)),
        Text(bubbleTime(event.timestampMs), style: TextStyle(fontSize: 11, color: color)),
        if (own) ...[const SizedBox(width: 3), Icon(icon, size: 14, color: failed ? Colors.redAccent : color)],
      ],
    );
    final aligned = Align(alignment: Alignment.bottomRight, widthFactor: 1, child: row);
    if (!overlay) return aligned;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(8)),
        child: row,
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({required this.reaction, required this.onTap});
  final Reaction reaction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: reaction.byMe ? scheme.primary.withValues(alpha: 0.15) : scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: reaction.byMe ? scheme.primary : scheme.outlineVariant),
        ),
        child: Text(
          reaction.count > 1 ? '${reaction.key} ${reaction.count}' : reaction.key,
          style: const TextStyle(fontSize: 14),
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onCancelBanner,
    required this.onAttach,
    required this.onRecordingDone,
    this.onMic,
    this.onEditLast,
    this.onPaste,
    this.recording,
    this.banner,
  });

  /// ↑ in an empty composer on desktop: edit your last message.
  final VoidCallback? onEditLast;

  /// Ctrl+V on desktop, which can paste files and images as well as text.
  final VoidCallback? onPaste;

  /// Null where the network takes no photos, videos or files.
  final VoidCallback? onAttach;

  /// Starts a voice note; shown in place of Send while the field is empty.
  final VoidCallback? onMic;

  /// How long the current voice note has been recording, or null.
  final Duration? recording;
  final void Function(bool send) onRecordingDone;
  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function(String text) onSend;

  /// Shown above the field while replying or editing.
  final Widget? banner;
  final VoidCallback onCancelBanner;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _empty = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    _empty = widget.controller.text.trim().isEmpty;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onText() {
    final empty = widget.controller.text.trim().isEmpty;
    if (empty != _empty) setState(() => _empty = empty);
  }

  void _send() {
    final text = widget.controller.text.trim();
    if (text.isEmpty) return;
    widget.controller.clear();
    widget.onSend(text).catchError((Object e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't send: $e")));
      }
    });
  }

  /// Desktop keys: Enter sends and Shift+Enter starts a new line, Esc
  /// cancels a reply or edit, ↑ in an empty composer edits.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent || widget.controller.value.composing.isValid) return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter when !shift:
        _send();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape when widget.banner != null:
        widget.onCancelBanner();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp when widget.controller.text.isEmpty && widget.onEditLast != null:
        widget.onEditLast!();
        return KeyEventResult.handled;
    }
    if (widget.onPaste != null && primaryKey(LogicalKeyboardKey.keyV).accepts(e, HardwareKeyboard.instance)) {
      widget.onPaste!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final banner = widget.banner;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (banner != null)
            Container(
              margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border(left: BorderSide(color: scheme.primary, width: 3)),
              ),
              child: Row(
                children: [
                  Expanded(child: banner),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: widget.onCancelBanner,
                  ),
                ],
              ),
            ),
          if (widget.recording != null)
            _RecordingBar(elapsed: widget.recording!, onDone: widget.onRecordingDone)
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.onAttach != null)
                    IconButton(
                      onPressed: widget.onAttach,
                      icon: Icon(Icons.add_circle_outline_rounded, color: scheme.onSurfaceVariant),
                      tooltip: 'Attach',
                    ),
                  Expanded(
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: isDesktop ? _onKey : null,
                      child: TextField(
                        controller: widget.controller,
                        focusNode: widget.focusNode,
                        autofocus: isDesktop,
                        minLines: 1,
                        maxLines: 6,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: 'Message',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_empty && widget.onMic != null)
                    IconButton(
                      onPressed: widget.onMic,
                      icon: Icon(Icons.mic_none_rounded, color: scheme.onSurfaceVariant),
                      tooltip: 'Voice note',
                    )
                  else
                    IconButton.filled(
                      onPressed: _empty ? null : _send,
                      icon: const Icon(Icons.arrow_upward_rounded),
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.primary,
                        disabledBackgroundColor: scheme.surfaceContainerHigh,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A MIME type from a file name, for pickers that don't report one.
String mimeFor(String path) => switch (path.split('.').last.toLowerCase()) {
  'jpg' || 'jpeg' => 'image/jpeg',
  'png' => 'image/png',
  'heic' => 'image/heic',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'mov' => 'video/quicktime',
  'mp4' || 'm4v' => 'video/mp4',
  'm4a' => 'audio/mp4',
  'mp3' => 'audio/mpeg',
  'ogg' || 'opus' => 'audio/ogg',
  'wav' => 'audio/wav',
  'pdf' => 'application/pdf',
  'txt' => 'text/plain',
  'csv' => 'text/csv',
  'zip' => 'application/zip',
  'doc' => 'application/msword',
  'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls' => 'application/vnd.ms-excel',
  'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt' => 'application/vnd.ms-powerpoint',
  'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  _ => 'application/octet-stream',
};

enum _Attach { photos, camera, video, file }

/// Replaces the composer while a voice note records: cancel, time, send.
class _RecordingBar extends StatelessWidget {
  const _RecordingBar({required this.elapsed, required this.onDone});
  final Duration elapsed;
  final void Function(bool send) onDone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => onDone(false),
            icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
            tooltip: 'Discard',
          ),
          const SizedBox(width: 4),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(clock(elapsed), style: const TextStyle(fontSize: 16, fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Recording voice note', style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          IconButton.filled(
            onPressed: () => onDone(true),
            icon: const Icon(Icons.arrow_upward_rounded),
            tooltip: 'Send voice note',
            style: IconButton.styleFrom(backgroundColor: scheme.primary),
          ),
        ],
      ),
    );
  }
}

/// "Seen" under your message in a DM; small avatars of readers in a group.
class _Seen extends StatelessWidget {
  const _Seen({required this.members, required this.group});
  final List<Member> members;
  final bool group;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (!group) {
      return Padding(
        padding: const EdgeInsets.only(top: 3, right: 4),
        child: Text('Seen', style: TextStyle(fontSize: 11, color: muted)),
      );
    }
    const max = 5;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in members.take(max))
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Tooltip(
                message: m.name ?? m.userId,
                child: MxcAvatar(name: m.name ?? m.userId, mxc: m.avatarMxc, size: 16),
              ),
            ),
          if (members.length > max)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('+${members.length - max}', style: TextStyle(fontSize: 11, color: muted)),
            ),
        ],
      ),
    );
  }
}

/// "Alice is typing…" above the composer.
class _TypingRow extends ConsumerWidget {
  const _TypingRow({required this.roomId});
  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typing = ref.watch(typingProvider(roomId)).value ?? const [];
    final scheme = Theme.of(context).colorScheme;
    String name(Member m) => m.name ?? m.userId;
    final text = switch (typing.length) {
      0 => '',
      1 => '${name(typing[0])} is typing',
      2 => '${name(typing[0])} and ${name(typing[1])} are typing',
      _ => '${typing.length} people are typing',
    };
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      alignment: Alignment.bottomLeft,
      child: typing.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
              child: Row(
                children: [
                  const _TypingDots(),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.3 + 0.7 * (((_anim.value * 3 - i) % 3) < 1 ? 1 : 0)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Members matching the name typed after "@", above the composer.
class _MentionSuggestions extends ConsumerWidget {
  const _MentionSuggestions({required this.roomId, required this.query, required this.onChoose});
  final String roomId;
  final String query;
  final void Function(Member) onChoose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(membersProvider(roomId)).value?.values ?? const <Member>[];
    final q = query.toLowerCase();
    final matches = [
      for (final m in members)
        if ((m.name ?? '').toLowerCase().split(' ').any((w) => w.startsWith(q)) ||
            m.userId.toLowerCase().startsWith('@$q'))
          m,
    ]..sort((a, b) => (a.name ?? a.userId).toLowerCase().compareTo((b.name ?? b.userId).toLowerCase()));
    if (matches.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              for (final m in matches.take(6))
                ListTile(
                  dense: true,
                  leading: MxcAvatar(name: m.name ?? m.userId, mxc: m.avatarMxc, size: 28),
                  title: Text(m.name ?? m.userId),
                  subtitle: m.name == null ? null : Text(m.userId, style: TextStyle(color: scheme.onSurfaceVariant)),
                  onTap: () => onChoose(m),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
