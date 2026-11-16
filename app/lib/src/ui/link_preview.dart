import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../rust/api/types.dart';
import '../state/media.dart';
import 'media_bubbles.dart';
import 'web_video.dart';

/// A link's preview inside a message bubble; opens the link on tap. A
/// Reddit post with a video plays it in the app instead.
class LinkPreviewCard extends ConsumerStatefulWidget {
  const LinkPreviewCard({super.key, required this.preview, required this.own});
  final LinkPreview preview;
  final bool own;

  @override
  ConsumerState<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends ConsumerState<LinkPreviewCard> {
  bool _busy = false;

  /// The video found behind a Reddit link, playing in the card.
  String? _stream;

  bool get _reddit => isRedditLink(widget.preview.url);

  @override
  void initState() {
    super.initState();
    // Start finding the video now, so tapping play doesn't wait for it.
    if (_reddit) redditVideoFor(widget.preview.url).ignore();
  }

  void _openExternally() {
    final uri = Uri.tryParse(widget.preview.url);
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _tap() async {
    if (!_reddit) return _openExternally();
    if (_busy) return;
    setState(() => _busy = true);
    String? stream;
    try {
      stream = await redditVideoFor(widget.preview.url);
    } catch (_) {
      stream = null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (stream == null) {
      // Not a video post (or Reddit wouldn't say): open it as before.
      _openExternally();
      return;
    }
    setState(() => _stream = stream);
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final own = widget.own;
    final scheme = Theme.of(context).colorScheme;
    final fg = own ? Colors.white : scheme.onSurface;
    final muted = own ? Colors.white70 : scheme.onSurfaceVariant;
    final width = (MediaQuery.sizeOf(context).width * 0.75 - 24).clamp(120.0, 300.0);
    final px = (width * MediaQuery.devicePixelRatioOf(context)).round();
    final image = preview.imageMxc == null
        ? null
        : ref.watch(mediaProvider((mxc: preview.imageMxc!, width: px, height: (px * 0.52).round()))).value;
    final play = Container(
      padding: const EdgeInsets.all(10),
      decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
      child: _busy
          ? const SizedBox.square(
              dimension: 28,
              child: Padding(
                padding: EdgeInsets.all(4),
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
              ),
            )
          : const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: own ? Colors.white.withValues(alpha: 0.15) : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _tap,
          onLongPress: _reddit ? _openExternally : null,
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_stream case final stream?)
                  InlineVideo(
                    url: stream,
                    name: preview.title ?? 'Reddit video',
                    width: width,
                    height: width * 0.75,
                    radius: 0,
                    autoplay: true,
                    thumbnail: image == null ? null : Image.memory(image, fit: BoxFit.cover, gaplessPlayback: true),
                  )
                else if (image != null)
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Image.memory(image, width: width, height: width * 0.52, fit: BoxFit.cover, gaplessPlayback: true),
                      if (_reddit) play,
                    ],
                  )
                else if (_reddit)
                  Container(width: width, height: width * 0.4, color: Colors.black87, alignment: Alignment.center, child: play),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (preview.siteName != null)
                        Text(preview.siteName!, style: TextStyle(fontSize: 11, color: muted)),
                      if (preview.title != null)
                        Text(preview.title!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
                      if (preview.description != null)
                        Text(preview.description!,
                            maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
