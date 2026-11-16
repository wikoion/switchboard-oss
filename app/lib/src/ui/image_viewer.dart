import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/media.dart';
import 'forward.dart';
import 'save_media.dart';

/// A photo full screen: pinch to zoom, tap or swipe down to close, save,
/// share and forward. Shows the thumbnail at once and swaps in the
/// original when it arrives.
class ImageViewer extends ConsumerWidget {
  const ImageViewer({
    super.key,
    required this.mxc,
    required this.thumbnail,
    this.alt = '',
    this.roomId,
    this.eventId,
  });

  final String mxc;
  final MediaKey thumbnail;
  final String alt;

  /// The message the photo came in, for Forward. Null while it's sending.
  final String? roomId;
  final String? eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final original = ref.watch(mediaProvider((mxc: mxc, width: 0, height: 0)));
    final thumb = ref.watch(mediaProvider(thumbnail));
    final bytes = original.value ?? thumb.value;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
        actions: [
          IconButton(
            icon: Icon(saveMediaIcon),
            tooltip: saveMediaLabel,
            onPressed: () => saveMedia(context, ref, mxc: mxc, name: alt, video: false),
          ),
          if (canShareMedia)
            IconButton(
              icon: const Icon(shareMediaIcon),
              tooltip: 'Share',
              onPressed: () => shareMedia(context, ref, mxc: mxc, name: alt, video: false),
            ),
          if ((roomId, eventId) case (final room?, final event?))
            IconButton(
              icon: const Icon(forwardIcon),
              tooltip: 'Forward',
              onPressed: () => forwardMessage(context, ref, roomId: room, eventId: event),
            ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 600) Navigator.pop(context);
        },
        child: Center(
          child: Hero(
            tag: mxc,
            child: bytes == null
                ? const CircularProgressIndicator(color: Colors.white)
                : InteractiveViewer(
                    maxScale: 5,
                    child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true, semanticLabel: alt),
                  ),
          ),
        ),
      ),
    );
  }
}
