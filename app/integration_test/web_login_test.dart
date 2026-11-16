// The real Linux sign-in window (linux/runner/web_login.cc) against a local
// page that leaves a value in each place a bridge looks. Linux only:
//   tool/linux-web-login-test.sh

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/hub.dart';
import 'package:switchboard/src/ui/link_screen.dart';
import 'package:switchboard/src/ui/theme.dart';

const _page = '''
<!doctype html>
<title>Test sign-in</title>
<style>body { font: 18px sans-serif; margin: 48px; }</style>
<h1>Test sign-in</h1>
<p id="status">Signing in…</p>
<script>
  localStorage.setItem('token', 'tok-1');
  fetch('/api/login', {method: 'POST', headers: {'X-Test': 'h1'}, body: JSON.stringify({csrf: 'csrf-9'})})
    .then(() => {
      document.getElementById('status').textContent = 'Signed in. Going home in 3 s.';
      setTimeout(() => { location.href = '/home'; }, 3000);
    });
</script>
''';

class TestSite {
  late final HttpServer _server;

  /// The Cookie header of each request for the sign-in page.
  final loginCookies = <String>[];
  DateTime? apiAt;

  String get origin => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final res = req.response;
      switch (req.uri.path) {
        case '/login':
          loginCookies.add(req.headers.value('cookie') ?? '');
          res.headers.add('set-cookie', 'sid=S1; HttpOnly; Path=/');
          res.headers.contentType = ContentType.html;
          res.write(_page);
        case '/api/login':
          await utf8.decodeStream(req);
          apiAt = DateTime.now();
          res.headers.add('set-cookie', 'api=A1; HttpOnly; Path=/api');
          res.headers.contentType = ContentType.json;
          res.write('{}');
        case '/home':
          res.headers.contentType = ContentType.html;
          res.write('<!doctype html><title>Home</title><h1>Signed in</h1>');
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Map<String, Object?> _field(String id, Map<String, Object?> source) =>
    {'id': id, 'required': true, 'sources': [source]};

Map<String, Object?> cookiesStep(String origin, {bool hidden = false}) => {
      'login_id': 'L1',
      'type': 'cookies',
      'step_id': 'test.cookies',
      'instructions': '',
      'cookies': {
        'url': '$origin/login',
        'wait_for_url_pattern': r'/home$',
        'hidden': hidden,
        'extract_js': "new Promise(r => r({title: 'extracted-' + location.hostname}))",
        'initial_cookies': [
          {'name': 'init', 'value': 'i1', 'domain': '127.0.0.1', 'http_only': true},
        ],
        'fields': [
          _field('sid', {'type': 'cookie', 'name': 'sid', 'cookie_domain': '127.0.0.1'}),
          _field('api', {'type': 'cookie', 'name': 'api', 'cookie_domain': '127.0.0.1'}),
          _field('init', {'type': 'cookie', 'name': 'init', 'cookie_domain': '127.0.0.1'}),
          _field('token', {'type': 'local_storage', 'name': 'token'}),
          _field('csrf', {'type': 'request_body', 'name': 'csrf', 'request_url_regex': r'/api/login$'}),
          _field('header', {'type': 'request_header', 'name': 'X-Test', 'request_url_regex': r'/api/login$'}),
          _field('title', {'type': 'special', 'name': 'test.title'}),
        ],
      },
    };

const everyValue = {
  'sid': 'S1',
  'api': 'A1',
  'init': 'i1',
  'token': 'tok-1',
  'csrf': 'csrf-9',
  'header': 'h1',
  'title': 'extracted-127.0.0.1',
};

class ScriptedHub {
  ScriptedHub(this.step);

  final Map<String, Object?> step;
  final submitted = Completer<Map<String, dynamic>>();
  DateTime? submittedAt;
  final cancelled = <String>[];

  Future<HubResponse> send(String method, String path, String? body) async {
    Object reply = const {};
    if (path.contains('/login/start/')) {
      reply = step;
    } else if (path.endsWith('/cookies')) {
      submittedAt = DateTime.now();
      submitted.complete((jsonDecode(body!) as Map).cast<String, dynamic>());
      reply = {'login_id': 'L1', 'type': 'complete', 'step_id': 'done', 'instructions': '', 'complete': {}};
    } else if (path.contains('/login/cancel/')) {
      cancelled.add(path);
    }
    return HubResponse(status: 200, body: jsonEncode(reply));
  }
}

final testBridge = Bridge(
  id: 'test',
  network: 'Test',
  reachable: true,
  supportsApi: true,
  flows: [LoginFlow(id: 'cookies', name: 'Web', description: 'Sign in on the web')],
);

Future<void> openLink(WidgetTester tester, ScriptedHub hub) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      hubProvider.overrideWithValue(HubApi(hub.send)),
      bridgesProvider.overrideWith((ref) async => [testBridge]),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const LinkScreen(bridgeId: 'test')),
              ),
              child: const Text('Add'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Add'));
}

/// Pumps in real time until [done], or fails after [timeout].
Future<void> waitFor(WidgetTester tester, bool Function() done, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// This app's windows that are on screen, by X11 window ID.
Future<Set<String>> visibleWindows() async {
  final r = await Process.run('xdotool', ['search', '--onlyvisible', '--pid', '$pid', '--name', '']);
  return {for (final l in '${r.stdout}'.split('\n')) if (l.trim().isNotEmpty) l.trim()};
}

Future<String?> signInWindow() async {
  final r = await Process.run('xdotool', ['search', '--onlyvisible', '--name', '^Sign in to Test\$']);
  final ids = '${r.stdout}'.trim();
  return ids.isEmpty ? null : ids.split('\n').first;
}

/// What a window manager sends when the close button is clicked. Xvfb has
/// no window manager, so it's sent straight to the window.
const _closeRequest = r'''
import ctypes, sys
x = ctypes.CDLL('libX11.so.6')
x.XOpenDisplay.restype = ctypes.c_void_p
x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x.XInternAtom.restype = ctypes.c_ulong
x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
x.XFlush.argtypes = [ctypes.c_void_p]
class ClientMessage(ctypes.Structure):
    _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong), ('send_event', ctypes.c_int),
                ('display', ctypes.c_void_p), ('window', ctypes.c_ulong), ('message_type', ctypes.c_ulong),
                ('format', ctypes.c_int), ('data', ctypes.c_long * 5), ('pad', ctypes.c_long * 12)]
d = x.XOpenDisplay(None)
w = int(sys.argv[1])
e = ClientMessage(type=33, send_event=1, display=d, window=w,
                  message_type=x.XInternAtom(d, b'WM_PROTOCOLS', 0), format=32)
e.data[0] = x.XInternAtom(d, b'WM_DELETE_WINDOW', 0)
x.XSendEvent(d, w, 0, 0, ctypes.byref(e))
x.XFlush(d)
''';

Future<String> waitForSignInWindow(WidgetTester tester) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final window = await signInWindow();
    if (window != null) return window;
    if (DateTime.now().isAfter(end)) fail('no sign-in window');
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late TestSite site;

  setUp(() async {
    site = TestSite();
    await site.start();
  });
  tearDown(() => site.stop());

  testWidgets('collects every kind of value and submits once the page reaches the URL', (tester) async {
    final hub = ScriptedHub(cookiesStep(site.origin));
    await openLink(tester, hub);
    await waitFor(tester, () => hub.submitted.isCompleted, timeout: const Duration(seconds: 40));

    expect(await hub.submitted.future, everyValue);
    expect(site.loginCookies.single, 'init=i1', reason: 'the initial cookie is set before the page loads');
    expect(hub.submittedAt!.difference(site.apiAt!), greaterThan(const Duration(milliseconds: 2500)),
        reason: 'everything was in after the request, but it waits for /home');
    await waitFor(tester, () => find.text('Test linked').evaluate().isNotEmpty);
    expect(await signInWindow(), isNull, reason: 'the window closes on submit');
  });

  testWidgets('a second login starts with an empty cookie jar; closing the window cancels', (tester) async {
    final hub = ScriptedHub(cookiesStep(site.origin));
    await openLink(tester, hub);
    await waitFor(tester, () => site.loginCookies.isNotEmpty);
    expect(site.loginCookies.single, 'init=i1', reason: 'no sid from the first login');

    final closed = await Process.run('python3', ['-I', '-c', _closeRequest, await waitForSignInWindow(tester)]);
    expect(closed.exitCode, 0, reason: '${closed.stderr}');
    await waitFor(tester, () => hub.cancelled.isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Add'), findsOneWidget, reason: 'back where the login started');
    expect(hub.submitted.isCompleted, isFalse);
  });

  testWidgets('a hidden login collects without a window on screen', (tester) async {
    final before = await visibleWindows();
    final hub = ScriptedHub(cookiesStep(site.origin, hidden: true));
    await openLink(tester, hub);
    await waitFor(tester, () => site.loginCookies.isNotEmpty);
    expect(await visibleWindows(), before);
    await waitFor(tester, () => hub.submitted.isCompleted, timeout: const Duration(seconds: 40));
    expect(await hub.submitted.future, everyValue);
  });
}
