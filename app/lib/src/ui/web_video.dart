// Videos that arrive as something else: an Instagram reel the bridge sent
// as its still, and Reddit posts shared as links. Both end up in the app's
// own player.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import '../state/hub.dart';
import '../state/rooms.dart';
import '../state/views.dart';
import 'login_window.dart';

/// Messages whose video should open by itself once it arrives: a reel the
/// user tapped while the bridge was still fetching it.
final autoplayProvider = NotifierProvider<Autoplay, Set<String>>(Autoplay.new);

class Autoplay extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void add(String eventId) => state = {...state, eventId};

  /// Whether [eventId] was waiting to play; it stops waiting either way.
  bool take(String eventId) {
    if (!state.contains(eventId)) return false;
    state = {...state}..remove(eventId);
    return true;
  }
}

/// Asks the room's bridge for the real media behind a stand-in, for the
/// account the room belongs to.
Future<void> resolveUnresolvedMedia(WidgetRef ref, String roomId, EventItem event) async {
  final eventId = event.eventId;
  final unresolved = event.unresolvedMedia;
  if (eventId == null || unresolved == null) return;
  final network = ref.read(roomSummaryProvider(roomId))?.network;
  final bridges = await ref.read(bridgesProvider.future);
  final bridge = bridges.where((b) => b.supportsApi && b.protocolId == network?.id).firstOrNull;
  if (bridge == null) throw StateError("This chat's bridge isn't available");
  await ref.read(hubProvider).resolveMedia(
        bridge.id,
        eventId,
        unresolved,
        loginId: ref.read(roomAccountProvider(roomId))?.id,
      );
}

/// A Reddit post or v.redd.it link, which may hold a video.
bool isRedditLink(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return host == 'redd.it' ||
      host == 'v.redd.it' ||
      host == 'reddit.com' ||
      host.endsWith('.reddit.com');
}

/// Finds the stream behind a Reddit link's video player, or null when the
/// post has no video. Reddit checks for a browser before serving pages, so
/// the page loads in a hidden web view, as a browser would load it.
const findRedditVideoJs = r'''
(() => {
  const el = document.querySelector('shreddit-player-2, shreddit-player');
  let src = el ? (el.getAttribute('src') || '') : '';
  if (!src) {
    const m = document.documentElement.outerHTML.match(/https:\/\/v\.redd\.it\/[^"'\s<>]+?\.m3u8[^"'\s<>]*/);
    src = m ? m[0] : '';
  }
  if (!src && document.querySelector('shreddit-post')) return 'none';
  return src.replace(/&amp;/g, '&');
})()
''';

/// Lookups already made or under way, by link, so a card resolves once
/// and a tap after scrolling past it is instant.
final _redditCache = <String, Future<String?>>{};

/// The previous lookup in line; one hidden web view at a time.
Future<void> _redditQueue = Future.value();

/// The video stream behind a Reddit link, looked up once per link and one
/// at a time. Cards call this as they appear, so a tap rarely waits.
Future<String?> redditVideoFor(String url) => _redditCache.putIfAbsent(url, () {
      final result = _redditQueue.then((_) => resolveRedditVideo(url)).catchError((Object _) => null);
      _redditQueue = result.then((_) {});
      // A failed lookup may be the network; let a later tap try again.
      result.then((stream) {
        if (stream == null) _redditCache.remove(url);
      });
      return result;
    });

Future<String?> resolveRedditVideo(String url, {Duration timeout = const Duration(seconds: 25)}) async {
  final found = Completer<String?>();
  Timer? poll;
  final deadline = Timer(timeout, () {
    if (!found.isCompleted) found.complete(null);
  });
  // The post has loaded without a player a few polls running: no video.
  var noVideo = 0;
  void offer(Object? value) {
    if (found.isCompleted) return;
    if (value is String && value.startsWith('https://')) {
      found.complete(value);
    } else if (value == 'none' && ++noVideo >= 4) {
      found.complete(null);
    }
  }

  if (defaultTargetPlatform == TargetPlatform.linux) {
    final window = LoginWindow();
    try {
      await window.open(url: url, title: 'Reddit', hidden: true);
      poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        try {
          offer(await window.evaluateJavascript(findRedditVideoJs));
        } catch (_) {}
      });
      final stream = await found.future;
      return stream == null ? null : redditDashFor(stream);
    } finally {
      poll?.cancel();
      deadline.cancel();
      await window.close();
    }
  }

  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(url)),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      // Don't let Reddit's own player start (and make sound) unseen.
      mediaPlaybackRequiresUserGesture: true,
      allowsInlineMediaPlayback: false,
    ),
    initialUserScripts: UnmodifiableListView(const []),
  );
  try {
    await view.run();
    poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      try {
        offer(await view.webViewController?.evaluateJavascript(source: findRedditVideoJs));
      } catch (_) {}
    });
    return await found.future;
  } finally {
    poll?.cancel();
    deadline.cancel();
    await view.dispose();
  }
}

/// Reddit's DASH manifest for an HLS one, with the same access token.
/// Arch's FFmpeg (behind the system libmpv on Linux) stops Reddit's
/// byte-range CMAF HLS after the first segment, but plays the DASH form of
/// the same video, sound included. iOS bundles its own FFmpeg and plays HLS.
String redditDashFor(String hls) {
  final uri = Uri.tryParse(hls);
  if (uri == null || !uri.path.endsWith('/HLSPlaylist.m3u8')) return hls;
  final token = uri.queryParameters['a'];
  return uri
      .replace(
        path: uri.path.replaceFirst(RegExp(r'HLSPlaylist\.m3u8$'), 'DASHPlaylist.mpd'),
        queryParameters: token == null ? null : {'a': token},
      )
      .toString();
}
