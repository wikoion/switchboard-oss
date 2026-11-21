import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/session.dart';
import 'accounts_screen.dart';
import 'channels_screen.dart';
import 'chat_media_screen.dart';
import 'chat_screen.dart';
import 'home_shell.dart';
import 'layout.dart';
import 'link_screen.dart';
import 'login_screen.dart';
import 'media_bubbles.dart';
import 'web_video.dart';
import 'notifications_screen.dart';
import 'search_screen.dart';
import 'search_settings_screen.dart';
import 'settings_screen.dart';

/// Where the app opens. Debug builds can override it for Simulator testing.
final initialRouteProvider = Provider<String>((_) => '/');

final routerProvider = Provider<GoRouter>((ref) {
  // Re-run redirects whenever the session changes.
  final refresh = ValueNotifier(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: ref.read(initialRouteProvider),
    refreshListenable: refresh,
    redirect: (context, state) {
      // switchboard://room/<id> from notifications: the host is the first
      // path segment.
      final uri = state.uri;
      if (uri.scheme == 'switchboard' && uri.host.isNotEmpty) {
        return '/${uri.host}${uri.path}';
      }
      final here = state.matchedLocation;
      final session = ref.read(sessionProvider);
      // Remember where the user was going while the session loads or they
      // sign in.
      final from = here == '/splash' || here == '/login'
          ? state.uri.queryParameters['from']
          : state.uri.toString();
      String hold(String at) => from == null || from == '/' ? at : '$at?from=${Uri.encodeQueryComponent(from)}';
      if (session.isLoading) return here == '/splash' ? null : hold('/splash');
      if (session.value == null) return here == '/login' ? null : hold('/login');
      if (here == '/login' || here == '/splash') return from ?? '/';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const _Splash()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      // Debug builds only: resolve a Reddit link's video and show what was
      // found, for checking the resolver against the real site.
      if (kDebugMode)
        GoRoute(
          path: '/debug/video',
          builder: (_, s) => _DebugVideo(url: s.uri.queryParameters['url'] ?? ''),
        ),
      // On wide windows the shell keeps the chat list beside these routes.
      ShellRoute(
        builder: (_, s, child) => HomeShell(location: s.uri, child: child),
        routes: [
          // Nested under the inbox so a chat opened from a link still has
          // the inbox to go back to.
          GoRoute(
            path: '/',
            pageBuilder: (_, s) => _page(s, const InboxHome()),
            routes: [
              GoRoute(
                path: 'room/:id',
                // ?event= opens the chat at that message, from search.
                pageBuilder: (_, s) => _page(
                  s,
                  ChatScreen(roomId: s.pathParameters['id']!, focusEventId: s.uri.queryParameters['event']),
                ),
                routes: [
                  GoRoute(
                    path: 'media',
                    pageBuilder: (_, s) => _page(s, ChatMediaScreen(roomId: s.pathParameters['id']!)),
                  ),
                ],
              ),
              GoRoute(
                path: 'search',
                pageBuilder: (_, s) => _page(
                  s,
                  SearchScreen(roomId: s.uri.queryParameters['room'], query: s.uri.queryParameters['q']),
                ),
              ),
              GoRoute(
                path: 'settings',
                pageBuilder: (_, s) => _page(s, const SettingsScreen()),
                routes: [
                  GoRoute(path: 'search', pageBuilder: (_, s) => _page(s, const SearchSettingsScreen())),
                  GoRoute(path: 'channels', pageBuilder: (_, s) => _page(s, const ChannelsScreen())),
                ],
              ),
              GoRoute(path: 'notifications', pageBuilder: (_, s) => _page(s, const NotificationsScreen())),
              GoRoute(
                path: 'accounts',
                pageBuilder: (_, s) => _page(s, const AccountsScreen()),
                routes: [
                  GoRoute(path: 'add', pageBuilder: (_, s) => _page(s, const AddAccountScreen())),
                  GoRoute(
                    path: 'link/:bridge',
                    pageBuilder: (_, s) => _page(
                      s,
                      LinkScreen(
                        bridgeId: s.pathParameters['bridge']!,
                        flowId: s.uri.queryParameters['flow'],
                        loginId: s.uri.queryParameters['login'],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

/// Desktop pages switch in place; phones slide as before.
Page<void> _page(GoRouterState s, Widget child) =>
    isDesktop ? NoTransitionPage(key: s.pageKey, child: child) : MaterialPage(key: s.pageKey, child: child);

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _DebugVideo extends StatefulWidget {
  const _DebugVideo({required this.url});
  final String url;

  @override
  State<_DebugVideo> createState() => _DebugVideoState();
}

class _DebugVideoState extends State<_DebugVideo> {
  String _status = 'Resolving…';
  String? _stream;
  final _watch = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    resolveRedditVideo(widget.url).then((stream) {
      if (!mounted) return;
      setState(() {
        _stream = stream;
        _status = 'After ${_watch.elapsedMilliseconds} ms: ${stream ?? 'no video'}';
      });
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Video resolver')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SelectableText('${widget.url}\n\n$_status', maxLines: 6),
            const SizedBox(height: 16),
            // Plays in place, as in a chat bubble.
            if (_stream case final stream?)
              Align(
                alignment: Alignment.centerLeft,
                child: InlineVideo(url: stream, name: 'debug', width: 280, height: 360, autoplay: true),
              ),
          ],
        ),
      );
}
