// Video, audio, voice-note and file bubbles. Media downloads through the
// core into a temporary cache, then plays with media_kit or opens in the
// share sheet (on desktop, in the default app).

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/media.dart';
import '../state/playback.dart';
import '../state/session.dart';
import 'layout.dart';
import 'save_media.dart';
import 'web_video.dart';

/// "1.2 MB" style sizes.
String fileSize(int? bytes) {
  if (bytes == null) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1000 && unit < units.length - 1) {
    size /= 1000;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${size.toStringAsFixed(size < 10 ? 1 : 0)} ${units[unit]}';
}

/// "1:05" style durations.
String clock(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

/// Downloads media to the temporary cache once and returns the file.
Future<File> cachedMedia(WidgetRef ref, String mxc, String name) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/media');
  await dir.create(recursive: true);
  final safeName = name.replaceAll(RegExp(r'[^\w.\- ]'), '_');
  final file = File('${dir.path}/${mxc.hashCode.toUnsigned(32)}-$safeName');
  if (await file.exists()) return file;
  final bytes = await ref.read(coreProvider).media(mxc: mxc, width: 0, height: 0);
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// Opens a file from a chat: in the share sheet on a phone (Save to Files
/// is there), in its default app on desktop.
Future<void> openChatFile(BuildContext context, WidgetRef ref, {required String mxc, required String name, String? mimetype}) async {
  final file = await cachedMedia(ref, mxc, name);
  if (!context.mounted) return;
  // share_plus can't share files on Linux.
  if (isDesktop) {
    if (!await launchUrl(Uri.file(file.path))) throw 'no app opens it';
    return;
  }
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(ShareParams(
    files: [XFile(file.path, mimeType: mimetype)],
    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
  ));
}

/// Asks where to save a file from a chat, then saves it there.
Future<void> saveChatFileAs(WidgetRef ref, {required String mxc, required String name, String? mimetype}) async {
  final file = await cachedMedia(ref, mxc, name);
  await FilePicker.saveFile(
    fileName: name,
    bytes: await file.readAsBytes(),
    mimeType: mimetype ?? 'application/octet-stream',
    dialogTitle: 'Save file',
  );
}

IconData fileIcon(String? mime) => switch (mime?.split('/').first) {
      'image' => Icons.image_outlined,
      'video' => Icons.movie_outlined,
      'audio' => Icons.audiotrack_outlined,
      _ when mime == 'application/pdf' => Icons.picture_as_pdf_outlined,
      _ when mime?.contains('zip') ?? false => Icons.folder_zip_outlined,
      _ => Icons.insert_drive_file_outlined,
    };

class FileBubble extends ConsumerStatefulWidget {
  const FileBubble({super.key, required this.name, this.mxc, this.mimetype, this.size, required this.own});
  final String name;
  final String? mxc;
  final String? mimetype;
  final int? size;
  final bool own;

  @override
  ConsumerState<FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends ConsumerState<FileBubble> {
  bool _busy = false;

  Future<void> _open() async {
    final mxc = widget.mxc;
    if (mxc == null || _busy) return;
    setState(() => _busy = true);
    try {
      await openChatFile(context, ref, mxc: mxc, name: widget.name, mimetype: widget.mimetype);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't open file: $e")));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAs() async {
    final mxc = widget.mxc;
    if (mxc == null || _busy) return;
    setState(() => _busy = true);
    try {
      await saveChatFileAs(ref, mxc: mxc, name: widget.name, mimetype: widget.mimetype);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't save file: $e")));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = widget.own ? Colors.white : scheme.onSurface;
    final muted = widget.own ? Colors.white70 : scheme.onSurfaceVariant;
    return InkWell(
      onTap: _open,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: widget.own ? Colors.white24 : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
            ),
            child: _busy
                ? Padding(padding: const EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                : Icon(fileIcon(widget.mimetype), color: fg),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.name,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                if (widget.size != null) Text(fileSize(widget.size), style: TextStyle(fontSize: 12, color: muted)),
              ],
            ),
          ),
          if (isDesktop && widget.mxc != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Save as',
              icon: Icon(Icons.download_rounded, color: muted),
              onPressed: _busy ? null : _saveAs,
            ),
        ],
      ),
    );
  }
}

/// A video's thumbnail with its length; tapping plays it in place, with the
/// player's controls. Their full-screen button fits the whole video to the
/// screen, turning the phone only for wide videos.
class VideoBubble extends ConsumerWidget {
  const VideoBubble({
    super.key,
    this.eventId,
    required this.name,
    this.mxc,
    this.thumbnailMxc,
    this.durationMs,
    this.width,
    this.height,
  });

  /// The message, so a video the user asked for (a reel being fetched)
  /// starts as soon as it arrives.
  final String? eventId;
  final String name;
  final String? mxc;
  final String? thumbnailMxc;
  final int? durationMs;
  final int? width;
  final int? height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maxW = (MediaQuery.sizeOf(context).width * 0.75 - 6).clamp(80.0, 280.0);
    final aspect = (width != null && height != null && height! > 0) ? width! / height! : 16 / 9;
    final h = (maxW / aspect).clamp(80.0, 360.0);
    final px = (maxW * MediaQuery.devicePixelRatioOf(context)).round();
    final thumb = thumbnailMxc == null
        ? null
        : ref.watch(mediaProvider((mxc: thumbnailMxc!, width: px, height: (px / aspect).round()))).value;
    final id = eventId;
    final autoplay = id != null && mxc != null && ref.watch(autoplayProvider).contains(id);
    if (autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(autoplayProvider.notifier).take(id));
    }
    return InlineVideo(
      mxc: mxc,
      name: name,
      width: maxW,
      height: h,
      videoAspect: width != null && height != null && height! > 0 ? width! / height! : null,
      durationMs: durationMs,
      autoplay: autoplay,
      thumbnail: thumb == null ? null : Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }
}

/// Plays a video where it sits: [thumbnail] and a play button until tapped
/// (or at once with [autoplay]), then the player. The source is a file on
/// the server ([mxc]) or a stream on the web ([url]).
class InlineVideo extends ConsumerStatefulWidget {
  const InlineVideo({
    super.key,
    this.mxc,
    this.url,
    required this.name,
    required this.width,
    required this.height,
    this.videoAspect,
    this.thumbnail,
    this.durationMs,
    this.autoplay = false,
    this.radius = 15,
  });

  final String? mxc;
  final String? url;
  final String name;
  final double width;
  final double height;

  /// Width over height, when the message says; otherwise read from the
  /// video once it loads. Decides the phone's orientation in full screen.
  final double? videoAspect;
  final Widget? thumbnail;
  final int? durationMs;
  final bool autoplay;
  final double radius;

  @override
  ConsumerState<InlineVideo> createState() => _InlineVideoState();
}

class _InlineVideoState extends ConsumerState<InlineVideo> {
  Player? _player;
  VideoController? _controller;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (widget.autoplay) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didUpdateWidget(InlineVideo old) {
    super.didUpdateWidget(old);
    if (widget.autoplay && !old.autoplay) _start();
  }

  @override
  void dispose() {
    if (_player case final p?) {
      PlaybackFocus.release(p);
      p.dispose();
    }
    super.dispose();
  }

  Future<void> _start() async {
    if (_player != null || _loading || (widget.mxc == null && widget.url == null)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final source = widget.url ?? (await cachedMedia(ref, widget.mxc!, widget.name)).path;
      if (!mounted) return;
      final player = Player();
      PlaybackFocus.watch(player);
      setState(() {
        _player = player;
        _controller = VideoController(player);
      });
      await player.open(Media(source));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Wide videos turn the phone sideways; tall ones (reels) stay upright,
  /// so neither is cropped or shrunk. The status bar hides either way.
  Future<void> _enterFullscreen() async {
    if (!Platform.isIOS && !Platform.isAndroid) return defaultEnterNativeFullscreen();
    final state = _player?.state;
    final aspect = widget.videoAspect ??
        ((state?.width ?? 0) > 0 && (state?.height ?? 0) > 0 ? state!.width! / state.height! : 16 / 9);
    await Future.wait([
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky, overlays: []),
      SystemChrome.setPreferredOrientations(aspect > 1
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final Widget child;
    if (controller != null && _error == null) {
      child = Video(
        controller: controller,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.contain,
        controls: _bubbleControls,
        onEnterFullscreen: _enterFullscreen,
      );
    } else {
      child = GestureDetector(
        onTap: _start,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: widget.width,
              height: widget.height,
              color: Colors.black87,
              child: widget.thumbnail,
            ),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
              child: _loading
                  ? const SizedBox.square(
                      dimension: 32,
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                      ),
                    )
                  : Icon(_error == null ? Icons.play_arrow_rounded : Icons.refresh_rounded,
                      color: Colors.white, size: 32),
            ),
            if (widget.durationMs != null)
              Positioned(
                left: 8,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(8)),
                  child: Text(clock(Duration(milliseconds: widget.durationMs!)),
                      style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
          ],
        ),
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(widget.radius), child: child);
  }
}

/// Controls for a video playing in its bubble. media_kit's own register
/// drag handlers even with their gestures off, which stopped the chat
/// scrolling (and swipe to reply) from a drag that started on the video.
/// These only take taps: play or pause, and full screen, where media_kit's
/// full controls take over.
Widget _bubbleControls(VideoState state) => _BubbleControls(state: state);

class _BubbleControls extends StatelessWidget {
  const _BubbleControls({required this.state});
  final VideoState state;

  @override
  Widget build(BuildContext context) {
    if (isFullscreen(context)) return AdaptiveVideoControls(state);
    final player = state.widget.controller.player;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: player.playOrPause,
            child: StreamBuilder<bool>(
              stream: player.stream.playing,
              initialData: player.state.playing,
              builder: (context, snap) => AnimatedOpacity(
                opacity: snap.data == true ? 0 : 1,
                duration: const Duration(milliseconds: 150),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: StreamBuilder<Duration>(
            stream: player.stream.position,
            initialData: player.state.position,
            builder: (context, snap) {
              final total = player.state.duration;
              final at = snap.data ?? Duration.zero;
              final progress = total.inMilliseconds == 0 ? 0.0 : at.inMilliseconds / total.inMilliseconds;
              return Container(
                padding: const EdgeInsets.fromLTRB(10, 16, 2, 2),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54],
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      clock(total - at),
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 3,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Full screen',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.fullscreen_rounded, color: Colors.white),
                      onPressed: () => enterFullscreen(context),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Plays a video full screen: a file on the server ([mxc]), or a stream
/// on the web ([url]), such as a Reddit video.
class VideoViewer extends ConsumerStatefulWidget {
  const VideoViewer({super.key, this.mxc, this.url, required this.name})
      : assert(mxc != null || url != null);
  final String? mxc;
  final String? url;
  final String name;

  @override
  ConsumerState<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends ConsumerState<VideoViewer> {
  late final _player = Player();
  late final _controller = VideoController(_player);
  Object? _error;

  @override
  void initState() {
    super.initState();
    PlaybackFocus.watch(_player);
    if (widget.url case final url?) {
      _player.open(Media(url)).catchError((Object e) {
        if (mounted) setState(() => _error = e);
      });
      return;
    }
    cachedMedia(ref, widget.mxc!, widget.name).then(
      (file) => _player.open(Media(file.path)),
      onError: (Object e) {
        if (mounted) setState(() => _error = e);
      },
    );
  }

  @override
  void dispose() {
    PlaybackFocus.release(_player);
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (widget.mxc case final mxc?)
            IconButton(
              icon: Icon(saveMediaIcon),
              tooltip: saveMediaLabel,
              onPressed: () => saveMedia(context, ref, mxc: mxc, name: widget.name, video: true),
            ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Text("Couldn't play video: $_error", style: const TextStyle(color: Colors.white))
            : Video(controller: _controller),
      ),
    );
  }
}

/// Audio and voice notes: play and pause inline with a progress bar.
class AudioBubble extends ConsumerStatefulWidget {
  const AudioBubble({super.key, required this.name, this.mxc, this.durationMs, required this.isVoice, required this.own});
  final String name;
  final String? mxc;
  final int? durationMs;
  final bool isVoice;
  final bool own;

  @override
  ConsumerState<AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends ConsumerState<AudioBubble> {
  Player? _player;
  final _subs = <StreamSubscription<Object?>>[];
  bool _loading = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    if (_player case final p?) {
      PlaybackFocus.release(p);
      p.dispose();
    }
    super.dispose();
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player != null) {
      await player.playOrPause();
      return;
    }
    final mxc = widget.mxc;
    if (mxc == null) return;
    setState(() => _loading = true);
    try {
      final file = await cachedMedia(ref, mxc, widget.name);
      final p = Player();
      PlaybackFocus.watch(p);
      _subs
        ..add(p.stream.playing.listen((v) => mounted ? setState(() => _playing = v) : null))
        ..add(p.stream.position.listen((v) => mounted ? setState(() => _position = v) : null))
        ..add(p.stream.duration.listen((v) => mounted && v > Duration.zero ? setState(() => _duration = v) : null))
        ..add(p.stream.completed.listen((done) {
          if (done) p.seek(Duration.zero).then((_) => p.pause());
        }));
      _player = p;
      await p.open(Media(file.path));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't play: $e")));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = widget.own ? Colors.white : scheme.onSurface;
    final muted = widget.own ? Colors.white70 : scheme.onSurfaceVariant;
    // Totals round up, so a short clip doesn't read as 0:00.
    final total = _duration ??
        (widget.durationMs == null ? null : Duration(seconds: (widget.durationMs! / 1000).ceil()));
    final progress = total == null || total.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          IconButton(
            onPressed: _toggle,
            icon: _loading
                ? SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                : Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: fg, size: 30),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!widget.isVoice)
                  Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg)),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    color: fg,
                    backgroundColor: muted.withValues(alpha: 0.3),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _playing || _position > Duration.zero ? clock(_position) : (total == null ? '' : clock(total)),
                  style: TextStyle(fontSize: 11, color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
