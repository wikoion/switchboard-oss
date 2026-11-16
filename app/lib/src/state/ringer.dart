import 'package:media_kit/media_kit.dart';

/// Plays the ringtone on a loop while a call rings. The notification
/// server can't be asked for a sound (swaync doesn't offer one), so the
/// app plays it.
class Ringer {
  Player? _player;

  Future<void> start() async {
    if (_player != null) return;
    final player = _player = Player();
    await player.setPlaylistMode(PlaylistMode.single);
    await player.open(Media('asset:///assets/sounds/ringtone.ogg'));
  }

  Future<void> stop() async {
    final player = _player;
    _player = null;
    await player?.dispose();
  }
}
