import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../rust/api/types.dart';
import '../../state/media.dart';
import '../../state/views.dart';
import '../theme.dart';

/// A round image from an mxc:// URI, with initials while it loads or if
/// there is none.
class MxcAvatar extends ConsumerWidget {
  const MxcAvatar({super.key, required this.name, this.mxc, this.size = 48});

  final String name;
  final String? mxc;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, shape: BoxShape.circle),
      child: Text(
        initials(name),
        style: TextStyle(
          fontSize: size * 0.36,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    final uri = mxc;
    if (uri == null || !uri.startsWith('mxc://')) return fallback;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final bytes = ref.watch(avatarProvider((mxc: uri, size: px)));
    // The core cuts it round: ClipOval has no anti-aliasing on Linux.
    return switch (bytes) {
      AsyncData(:final value) =>
        Image.memory(value, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
      _ => fallback,
    };
  }
}

String initials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  final first = words.first.runes.first;
  if (words.length == 1) return String.fromCharCode(first).toUpperCase();
  return (String.fromCharCode(first) + String.fromCharCode(words.last.runes.first)).toUpperCase();
}

/// The small network badge drawn over an avatar's corner.
class NetworkBadge extends ConsumerWidget {
  const NetworkBadge({super.key, required this.network, this.size = 18});

  final Network network;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ring = Theme.of(context).colorScheme.surface;
    final color = networkColor(network.id);
    final glyph = networkGlyph(network.id);
    Widget inner = Container(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      alignment: Alignment.center,
      padding: EdgeInsets.all(size * 0.2),
      child: glyph != null
          ? SvgPicture.asset(glyph, colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn))
          : Text(
              network.name.isEmpty ? '?' : network.name[0],
              style: TextStyle(fontSize: size * 0.5, color: Colors.white, fontWeight: FontWeight.w700),
            ),
    );
    // Bridges for networks without a bundled glyph may host their own icon.
    final mxc = network.avatarMxc;
    if (glyph == null && mxc != null && mxc.startsWith('mxc://')) {
      final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
      final bytes = ref.watch(avatarProvider((mxc: mxc, size: px)));
      if (bytes case AsyncData(:final value)) {
        inner = Image.memory(value, fit: BoxFit.cover, gaplessPlayback: true);
      }
    }
    return Container(
      width: size + 4,
      height: size + 4,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
      child: inner,
    );
  }
}

/// The note icon shown for Note to Self chats.
class NoteAvatar extends StatelessWidget {
  const NoteAvatar({super.key, this.size = 48});
  final double size;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset('assets/notes/note_to_self.svg', width: size, height: size);
}

/// An avatar with the room's network badge in the bottom-right corner.
/// Chats with yourself show the note icon.
class RoomAvatar extends ConsumerWidget {
  const RoomAvatar({super.key, required this.room, this.size = 52});

  final RoomSummary room;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = room.network;
    final note = ref.watch(isSelfChatProvider(room.id));
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (note) NoteAvatar(size: size) else MxcAvatar(name: room.name, mxc: room.avatarMxc, size: size),
          if (network != null)
            Positioned(
              right: -3,
              bottom: -3,
              child: NetworkBadge(network: network, size: size * 0.34),
            ),
        ],
      ),
    );
  }
}
