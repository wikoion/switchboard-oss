import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// Only one video or voice note plays at a time: starting one pauses
/// whichever was playing.
class PlaybackFocus {
  PlaybackFocus._();

  static Player? _current;
  static final _subs = <Player, StreamSubscription<bool>>{};

  /// Follows [player], so that when it starts (from its own controls too)
  /// it takes over from the one playing.
  static void watch(Player player) {
    _subs[player] ??= player.stream.playing.listen((playing) {
      if (playing) _claim(player);
    });
  }

  static void _claim(Player player) {
    final previous = _current;
    _current = player;
    if (previous != null && !identical(previous, player)) previous.pause();
  }

  /// Forgets [player]; call before disposing it.
  static void release(Player player) {
    _subs.remove(player)?.cancel();
    if (identical(_current, player)) _current = null;
  }
}
