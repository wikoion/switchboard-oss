import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import 'session.dart';

/// An mxc:// URI plus the thumbnail size wanted (0 × 0 for the original).
typedef MediaKey = ({String mxc, int width, int height});

/// Media bytes, fetched through the core's cache and kept for the session.
final mediaProvider = FutureProvider.family<Uint8List, MediaKey>((ref, key) {
  return ref.watch(coreProvider).media(mxc: key.mxc, width: key.width, height: key.height);
});

/// A square avatar of the given size in pixels, cropped by the server.
final avatarProvider = FutureProvider.family<Uint8List, ({String mxc, int size})>((ref, key) {
  return ref.watch(coreProvider).avatar(mxc: key.mxc, size: key.size);
});

/// Synapse's preview of a link, kept for the session.
final linkPreviewProvider = FutureProvider.family<LinkPreview?, String>((ref, url) {
  return ref.watch(coreProvider).linkPreview(url: url);
});
