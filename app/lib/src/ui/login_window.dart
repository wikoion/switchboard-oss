// The sign-in window on Linux, where flutter_inappwebview has no web view:
// a WebKitGTK window the runner opens (linux/runner/web_login.cc), on a fresh
// cookie jar each time. web_login.dart drives it as it drives InAppWebView.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../state/hub.dart';

const loginWindowChannel = MethodChannel('switchboard/web_login');

class LoginWindow {
  LoginWindow({this.onLoadStop, this.onUrlChanged, this.onHandler, this.onClosed}) : id = ++_lastId;

  final int id;
  final void Function(String? url)? onLoadStop;
  final void Function(String? url)? onUrlChanged;

  /// A page script called `flutter_inappwebview.callHandler(name, ...args)`.
  final void Function(String name, List<Object?> args)? onHandler;

  /// The user closed the window.
  final void Function()? onClosed;

  static int _lastId = 0;
  static final _open = <int, LoginWindow>{};

  bool get isOpen => _open.containsKey(id);

  Future<void> open({
    required String url,
    required String title,
    String? userAgent,
    List<InitialCookie> cookies = const [],
    List<String> scripts = const [],
    bool hidden = false,
  }) async {
    loginWindowChannel.setMethodCallHandler(_dispatch);
    _open[id] = this;
    try {
      await loginWindowChannel.invokeMethod<void>('open', {
        'id': id,
        'url': url,
        'title': title,
        'userAgent': userAgent,
        'hidden': hidden,
        'scripts': scripts,
        'cookies': [
          for (final c in cookies)
            {
              'name': c.name,
              'value': c.value,
              'domain': c.domain,
              'path': c.path ?? '/',
              'secure': c.secure,
              'httpOnly': c.httpOnly,
            },
        ],
      });
    } catch (_) {
      _open.remove(id);
      rethrow;
    }
  }

  /// Cookies for [url]'s host and its parent domains, HttpOnly included.
  Future<List<({String name, String value, String domain})>> getCookies(String url) async {
    final list = await loginWindowChannel.invokeListMethod<Map<Object?, Object?>>('getCookies', {'id': id, 'url': url});
    return [
      for (final c in list ?? const <Map<Object?, Object?>>[])
        (name: '${c['name']}', value: '${c['value']}', domain: '${c['domain']}'),
    ];
  }

  /// Runs [source] in the page; strings, numbers and booleans come back as
  /// they are, other values as JSON.
  Future<Object?> evaluateJavascript(String source) =>
      loginWindowChannel.invokeMethod<Object?>('evaluateJavascript', {'id': id, 'source': source});

  Future<void> close() async {
    if (_open.remove(id) == null) return;
    try {
      await loginWindowChannel.invokeMethod<void>('close', {'id': id});
    } on PlatformException {
      // Nothing left to close.
    }
  }

  static Future<void> _dispatch(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    final window = _open[args['id']];
    if (window == null) return;
    final url = args['url'] as String?;
    switch (call.method) {
      case 'onLoadStop':
        window.onLoadStop?.call(url);
      case 'onUrlChanged':
        window.onUrlChanged?.call(url);
      case 'onMessage':
        try {
          final m = jsonDecode(args['message'] as String? ?? '');
          if (m is Map && m['name'] is String) {
            window.onHandler?.call(m['name'] as String, (m['args'] as List?)?.cast<Object?>() ?? const []);
          }
        } catch (_) {}
      case 'onClosed':
        _open.remove(window.id);
        window.onClosed?.call();
    }
  }
}
