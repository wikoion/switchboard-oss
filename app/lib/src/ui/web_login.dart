// The `cookies` login step: the network's own sign-in page in a web view,
// from which the app collects the cookies, tokens or request values the
// bridge asks for, then hands them to the bridge.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../state/hub.dart';
import 'login_window.dart';

/// Collects a cookie step's fields as values turn up, and says when the
/// login can be submitted. Kept apart from the web view so it can be tested.
class CookieCollector {
  CookieCollector(this.params);

  final CookieParams params;
  final Map<String, String> values = {};

  /// Offers a value found by a source of [type] and [name]; each field
  /// with a matching source takes it if its pattern allows. Returns whether
  /// anything changed.
  bool offer(String type, String name, String value, {String? url, String? domain}) {
    var changed = false;
    for (final f in params.fields) {
      for (final s in f.sources) {
        if (s.type != type || s.name != name) continue;
        if (url != null && s.requestUrlRegex != null && !RegExp(s.requestUrlRegex!).hasMatch(url)) continue;
        if (domain != null && s.cookieDomain != null && !_domainMatches(domain, s.cookieDomain!)) continue;
        if (!f.accepts(value) || values[f.id] == value) continue;
        values[f.id] = value;
        changed = true;
      }
    }
    return changed;
  }

  /// Takes the extraction script's result, an object keyed by field ID.
  bool offerExtracted(Map<String, dynamic> result) {
    var changed = false;
    for (final f in params.fields) {
      final v = result[f.id];
      if (v is! String || !f.accepts(v) || values[f.id] == v) continue;
      values[f.id] = v;
      changed = true;
    }
    return changed;
  }

  bool get hasRequired => params.fields.where((f) => f.required).every((f) => values.containsKey(f.id));

  /// Ready to submit by itself: every required value, and the page has
  /// reached the URL the bridge waits for, if it gave one.
  bool readyAt(String? url) {
    if (!hasRequired) return false;
    final wait = params.waitForUrlPattern;
    return wait == null || (url != null && RegExp(wait).hasMatch(url));
  }

  /// Cookie names to read, by the domain they live on.
  Map<String, Set<String>> get cookieNames {
    final out = <String, Set<String>>{};
    for (final f in params.fields) {
      for (final s in f.sources) {
        if (s.type == 'cookie') out.putIfAbsent(s.cookieDomain ?? '', () => {}).add(s.name);
      }
    }
    return out;
  }

  Set<String> get localStorageKeys => {
        for (final f in params.fields)
          for (final s in f.sources)
            if (s.type == 'local_storage') s.name,
      };

  /// Request header and body sources, for the hooks injected into pages.
  List<CookieSource> get requestSources => [
        for (final f in params.fields)
          for (final s in f.sources)
            if (s.type == 'request_header' || s.type == 'request_body') s,
      ];
}

bool _domainMatches(String cookieDomain, String wanted) {
  final d = cookieDomain.startsWith('.') ? cookieDomain.substring(1) : cookieDomain;
  final w = wanted.startsWith('.') ? wanted.substring(1) : wanted;
  return d == w || d.endsWith('.$w');
}

/// A script run at document start that wraps fetch and XMLHttpRequest and
/// reports the wanted request headers and body fields to the app.
String requestHookScript(List<CookieSource> sources) {
  final wanted = jsonEncode([
    for (final s in sources) {'type': s.type, 'name': s.name, 're': s.requestUrlRegex ?? ''},
  ]);
  return '''
(function() {
  if (window.__sbHooked) return;
  window.__sbHooked = true;
  const wanted = $wanted;
  function report(type, name, value, url) {
    try { window.flutter_inappwebview.callHandler('sbFound', type, name, String(value), String(url)); } catch (e) {}
  }
  function bodyField(body, name) {
    try {
      if (!body) return null;
      if (typeof FormData !== 'undefined' && body instanceof FormData) return body.get(name);
      if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) return body.get(name);
      if (typeof body === 'string') {
        try { const j = JSON.parse(body); if (j && typeof j === 'object' && name in j) return j[name]; } catch (e) {}
        return new URLSearchParams(body).get(name);
      }
    } catch (e) {}
    return null;
  }
  function inspect(url, headers, body) {
    for (const w of wanted) {
      if (w.re && !(new RegExp(w.re)).test(url)) continue;
      if (w.type === 'request_header') {
        const key = Object.keys(headers).find(k => k.toLowerCase() === w.name.toLowerCase());
        if (key && headers[key]) report(w.type, w.name, headers[key], url);
      } else if (w.type === 'request_body') {
        const v = bodyField(body, w.name);
        if (v) report(w.type, w.name, v, url);
      }
    }
  }
  const origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function(input, init) {
      try {
        const url = typeof input === 'string' ? input : (input && input.url) || '';
        const headers = {};
        const h = (init && init.headers) || (input && input.headers);
        if (h) {
          if (typeof h.forEach === 'function') h.forEach((v, k) => { headers[k] = v; });
          else Object.assign(headers, h);
        }
        inspect(new URL(url, location.href).href, headers, init && init.body);
      } catch (e) {}
      return origFetch.apply(this, arguments);
    };
  }
  const open = XMLHttpRequest.prototype.open;
  const setHeader = XMLHttpRequest.prototype.setRequestHeader;
  const send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url) {
    try { this.__sbUrl = new URL(url, location.href).href; this.__sbHeaders = {}; } catch (e) {}
    return open.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function(k, v) {
    try { if (this.__sbHeaders) this.__sbHeaders[k] = v; } catch (e) {}
    return setHeader.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function(body) {
    try { inspect(this.__sbUrl || '', this.__sbHeaders || {}, body); } catch (e) {}
    return send.apply(this, arguments);
  };
})();
''';
}

/// flutter_inappwebview has no Linux web view, so there the page opens in a
/// WebKitGTK window of its own ([LoginWindow]).
bool get _inWindow => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

class WebLoginStep extends StatefulWidget {
  const WebLoginStep({
    super.key,
    required this.step,
    required this.network,
    required this.busy,
    required this.onSubmit,
    required this.onCancel,
  });

  final LoginStep step;
  final String network;
  final bool busy;
  final void Function(Map<String, String>) onSubmit;

  /// Cancel, or the sign-in window closed by the user.
  final VoidCallback onCancel;

  @override
  State<WebLoginStep> createState() => _WebLoginStepState();
}

class _WebLoginStepState extends State<WebLoginStep> {
  late final CookieCollector _collector = CookieCollector(widget.step.cookies!);
  InAppWebViewController? _controller;
  LoginWindow? _window;
  Timer? _poll;
  String? _url;
  bool _ready = false;
  bool _submitted = false;
  double _progress = 0;
  String? _windowError;

  CookieParams get _params => widget.step.cookies!;

  @override
  void initState() {
    super.initState();
    if (_inWindow) {
      _openWindow();
    } else {
      unawaited(_prepareCookies());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_window?.close());
    super.dispose();
  }

  /// Linux: the page in its own window, with the same scripts and cookies
  /// as the InAppWebView below.
  void _openWindow() {
    final window = LoginWindow(
      onLoadStop: _loaded,
      onUrlChanged: _urlChanged,
      onHandler: _handle,
      onClosed: () {
        if (!_submitted && mounted) widget.onCancel();
      },
    );
    _window = window;
    window
        .open(
          url: _params.url,
          title: 'Sign in to ${widget.network}',
          userAgent: _params.userAgent,
          cookies: _params.initialCookies,
          scripts: [if (_collector.requestSources.isNotEmpty) requestHookScript(_collector.requestSources)],
          hidden: _params.hidden,
        )
        .catchError((Object e) {
          if (mounted) setState(() => _windowError = '$e');
        });
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _collect());
  }

  /// Starts from a clean cookie jar, so linking a second account on the
  /// same network doesn't reuse the first one's session, then sets any
  /// cookies the bridge passed to continue a login.
  Future<void> _prepareCookies() async {
    final jar = CookieManager.instance();
    await jar.deleteAllCookies();
    for (final c in _params.initialCookies) {
      final domain = c.domain.startsWith('.') ? c.domain.substring(1) : c.domain;
      await jar.setCookie(
        url: WebUri('https://$domain${c.path ?? '/'}'),
        name: c.name,
        value: c.value,
        domain: c.domain,
        path: c.path ?? '/',
        isSecure: c.secure,
        isHttpOnly: c.httpOnly,
      );
    }
    if (mounted) setState(() => _ready = true);
  }

  bool get _pageOpen => _controller != null || (_window?.isOpen ?? false);

  /// Name, value and domain of each cookie for [url], from whichever view
  /// shows the page.
  Future<List<(String, String, String?)>> _cookies(String url) async {
    final window = _window;
    if (window != null) {
      return [for (final c in await window.getCookies(url)) (c.name, c.value, c.domain)];
    }
    final cookies = await CookieManager.instance().getCookies(url: WebUri(url), webViewController: _controller);
    return [for (final c in cookies) (c.name, '${c.value}', c.domain)];
  }

  Future<Object?> _evaluate(String source) async =>
      _window != null ? _window!.evaluateJavascript(source) : _controller?.evaluateJavascript(source: source);

  Future<void> _collect() async {
    if (!_pageOpen || _submitted) return;
    var changed = false;
    for (final MapEntry(key: domain, value: names) in _collector.cookieNames.entries) {
      final host = domain.isEmpty ? Uri.tryParse(_url ?? _params.url)?.host ?? '' : domain.replaceFirst(RegExp(r'^\.'), '');
      if (host.isEmpty) continue;
      try {
        for (final (name, value, cookieDomain) in await _cookies('https://$host')) {
          if (!names.contains(name)) continue;
          changed |= _collector.offer('cookie', name, value, domain: cookieDomain ?? host);
        }
      } catch (_) {}
    }
    for (final key in _collector.localStorageKeys) {
      try {
        final v = await _evaluate('window.localStorage.getItem(${jsonEncode(key)})');
        if (v is String) changed |= _collector.offer('local_storage', key, v);
      } catch (_) {}
    }
    if (changed && mounted) setState(() {});
    _maybeSubmit();
  }

  /// Runs the bridge's extraction script; it resolves once it finds what
  /// it looks for, which may be a page or two later.
  Future<void> _runExtractor() async {
    final js = _params.extractJs;
    if (js == null || !_pageOpen) return;
    try {
      await _evaluate('''
(async () => {
  try {
    const r = await (
$js
);
    window.flutter_inappwebview.callHandler('sbExtracted', JSON.stringify(r || {}));
  } catch (e) {}
})();
''');
    } catch (_) {}
  }

  void _loaded(String? url) {
    _url = url;
    unawaited(_runExtractor());
    unawaited(_collect());
  }

  void _urlChanged(String? url) {
    _url = url;
    _maybeSubmit();
  }

  /// What the injected scripts report: request values, and the
  /// extraction script's result.
  void _handle(String name, List<dynamic> args) {
    var changed = false;
    if (name == 'sbFound' && args.length >= 4) {
      changed = _collector.offer('${args[0]}', '${args[1]}', '${args[2]}', url: '${args[3]}');
    } else if (name == 'sbExtracted' && args.isNotEmpty) {
      try {
        final r = jsonDecode('${args.first}');
        changed = r is Map && _collector.offerExtracted(r.cast<String, dynamic>());
      } catch (_) {}
    }
    if (!changed) return;
    if (mounted) setState(() {});
    _maybeSubmit();
  }

  void _maybeSubmit() {
    if (_submitted || !_collector.readyAt(_url)) return;
    _submit();
  }

  void _submit() {
    if (_submitted) return;
    _submitted = true;
    _poll?.cancel();
    unawaited(_window?.close());
    widget.onSubmit(Map.of(_collector.values));
  }

  void _cancel() {
    _poll?.cancel();
    unawaited(_window?.close());
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_inWindow) return _windowStatus(scheme);
    if (!_ready) return const Center(child: CircularProgressIndicator());

    final view = InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_params.url)),
      initialSettings: InAppWebViewSettings(
        userAgent: _params.userAgent ?? '',
        javaScriptEnabled: true,
        thirdPartyCookiesEnabled: true,
        sharedCookiesEnabled: true,
      ),
      initialUserScripts: UnmodifiableListView([
        if (_collector.requestSources.isNotEmpty)
          UserScript(
            source: requestHookScript(_collector.requestSources),
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            forMainFrameOnly: false,
          ),
      ]),
      onWebViewCreated: (c) {
        _controller = c;
        for (final name in ['sbFound', 'sbExtracted']) {
          c.addJavaScriptHandler(handlerName: name, callback: (args) => _handle(name, args));
        }
        _poll = Timer.periodic(const Duration(seconds: 1), (_) => _collect());
      },
      onLoadStop: (c, url) => _loaded(url?.toString()),
      onUpdateVisitedHistory: (c, url, _) => _urlChanged(url?.toString()),
      onProgressChanged: (c, p) {
        if (mounted) setState(() => _progress = p / 100);
      },
    );

    if (_params.hidden) {
      return Stack(
        children: [
          Positioned(left: 0, top: 0, width: 1, height: 1, child: Opacity(opacity: 0, child: view)),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }

    final found = _collector.hasRequired;
    return Column(
      children: [
        if (_progress < 1) LinearProgressIndicator(value: _progress, minHeight: 2),
        Expanded(child: view),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(top: BorderSide(color: scheme.outlineVariant, width: 0.5)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.busy || _submitted
                      ? 'Linking ${widget.network}…'
                      : found
                          ? 'Signed in. Finishing…'
                          : 'Sign in to ${widget.network} above. This closes by itself when you\'re in.',
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ),
              if (found && !_submitted && !widget.busy)
                TextButton(onPressed: _submit, child: const Text('Done')),
              if (widget.busy || _submitted)
                const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
        ),
      ],
    );
  }

  /// Linux: what shows in the app while the page is in its own window.
  Widget _windowStatus(ColorScheme scheme) {
    final error = _windowError;
    if (error == null && _params.hidden && !_submitted) return const Center(child: CircularProgressIndicator());
    final linking = widget.busy || _submitted;
    final found = _collector.hasRequired;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(error == null ? Icons.open_in_new_rounded : Icons.error_outline_rounded,
            size: 48, color: error == null ? scheme.primary : scheme.error),
        const SizedBox(height: 16),
        Text(
          error != null
              ? "Couldn't open the sign-in window: $error"
              : linking
                  ? 'Linking ${widget.network}…'
                  : found
                      ? 'Signed in. Finishing…'
                      : "Sign in to ${widget.network} in the window that opened. This closes by itself when you're in.",
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: 24),
        if (linking)
          const Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)))
        else ...[
          if (found && error == null) ...[
            FilledButton(onPressed: _submit, child: const Text('Done')),
            const SizedBox(height: 8),
          ],
          TextButton(onPressed: _cancel, child: const Text('Cancel')),
        ],
      ],
    );
  }
}
