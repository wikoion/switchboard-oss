import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/state/hub.dart';
import 'package:switchboard/src/ui/login_window.dart';
import 'package:switchboard/src/ui/theme.dart';
import 'package:switchboard/src/ui/web_login.dart';

// One of each source a cookies step can name, plus a URL to wait for.
LoginStep testStep({bool hidden = false}) => LoginStep.fromJson({
      'login_id': 'L1',
      'type': 'cookies',
      'step_id': 'test.cookies',
      'cookies': {
        'url': 'https://example.com/login',
        'user_agent': 'TestAgent/1',
        'wait_for_url_pattern': r'^https://example\.com/home$',
        'hidden': hidden,
        'fields': [
          {'id': 'sid', 'required': true, 'sources': [{'type': 'cookie', 'name': 'sid', 'cookie_domain': 'example.com'}]},
          {'id': 'token', 'required': true, 'sources': [{'type': 'local_storage', 'name': 'token'}]},
          {
            'id': 'csrf',
            'required': true,
            'sources': [
              {'type': 'request_body', 'name': 'csrf', 'request_url_regex': r'^https://example\.com/api/'},
            ],
          },
          {'id': 'title', 'required': true, 'sources': [{'type': 'special', 'name': 'test.title'}]},
        ],
        'initial_cookies': [
          {'name': 'init', 'value': 'i1', 'domain': '.example.com', 'secure': true, 'http_only': true},
        ],
        'extract_js': 'Promise.resolve({title: document.title})',
      },
    });

/// Stands in for linux/runner/web_login.cc.
class FakeWindow {
  FakeWindow(this.tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(loginWindowChannel, (call) async {
      calls.add(call);
      final source = '${(call.arguments as Map)['source']}';
      return switch (call.method) {
        'getCookies' => [
            {'name': 'sid', 'value': 'S1', 'domain': '.example.com', 'path': '/', 'httpOnly': true, 'secure': true},
            {'name': 'other', 'value': 'x', 'domain': 'example.com', 'path': '/', 'httpOnly': false, 'secure': false},
          ],
        'evaluateJavascript' when source.contains('localStorage') => 'tok-1',
        _ => null,
      };
    });
  }

  final WidgetTester tester;
  final calls = <MethodCall>[];

  Map<Object?, Object?> get opened => calls.singleWhere((c) => c.method == 'open').arguments as Map;
  Iterable<MethodCall> named(String method) => calls.where((c) => c.method == method);

  /// A callback from the native side for the open window.
  Future<void> send(String method, [Map<String, Object?> args = const {}]) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      loginWindowChannel.name,
      loginWindowChannel.codec.encodeMethodCall(MethodCall(method, {'id': opened['id'], ...args})),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> handler(String name, List<Object?> args) =>
      send('onMessage', {'message': jsonEncode({'name': name, 'args': args})});
}

class Outcome {
  Map<String, String>? submitted;
  var cancelled = 0;
}

Future<Outcome> pumpStep(WidgetTester tester, LoginStep step) async {
  final out = Outcome();
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: WebLoginStep(
        step: step,
        network: 'Test',
        busy: false,
        onSubmit: (v) => out.submitted = v,
        onCancel: () => out.cancelled++,
      ),
    ),
  ));
  return out;
}

void main() {
  final linux = TargetPlatformVariant.only(TargetPlatform.linux);
  const waiting = "Sign in to Test in the window that opened. This closes by itself when you're in.";

  testWidgets('opens the page in a window, collects every source and submits at the URL', (tester) async {
    final native = FakeWindow(tester);
    final out = await pumpStep(tester, testStep());

    final open = native.opened;
    expect(open['url'], 'https://example.com/login');
    expect(open['title'], 'Sign in to Test');
    expect(open['userAgent'], 'TestAgent/1');
    expect(open['hidden'], isFalse);
    expect(open['cookies'], [
      {'name': 'init', 'value': 'i1', 'domain': '.example.com', 'path': '/', 'secure': true, 'httpOnly': true},
    ]);
    expect((open['scripts'] as List).single, allOf(contains('sbFound'), contains('"name":"csrf"')));
    expect(find.text(waiting), findsOneWidget);
    expect(find.text('Done'), findsNothing);

    // A load runs the bridge's extraction script and reads cookies and
    // local storage.
    await native.send('onLoadStop', {'url': 'https://example.com/login'});
    await tester.pump();
    expect(native.named('evaluateJavascript').where((c) => '${(c.arguments as Map)['source']}'.contains('sbExtracted')),
        hasLength(1));
    expect(native.named('getCookies').first.arguments, {'id': open['id'], 'url': 'https://example.com'});

    // A request to another URL doesn't count.
    await native.handler('sbFound', ['request_body', 'csrf', 'C0', 'https://other.example/api/login']);
    await native.handler('sbFound', ['request_body', 'csrf', 'C1', 'https://example.com/api/login']);
    await native.handler('sbExtracted', [jsonEncode({'title': 'T1'})]);
    await tester.pump(const Duration(seconds: 1));
    expect(out.submitted, isNull, reason: 'the page is not at the URL the bridge waits for');
    expect(find.text('Signed in. Finishing…'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    await native.send('onUrlChanged', {'url': 'https://example.com/home'});
    expect(out.submitted, {'sid': 'S1', 'token': 'tok-1', 'csrf': 'C1', 'title': 'T1'});
    expect(native.calls.last.method, 'close');
    expect(native.calls.last.arguments, {'id': open['id']});
    expect(out.cancelled, 0);
  }, variant: linux);

  testWidgets('closing the window cancels the login', (tester) async {
    final native = FakeWindow(tester);
    final out = await pumpStep(tester, testStep());
    await native.send('onClosed');
    expect(out.cancelled, 1);
    expect(out.submitted, isNull);

    // The window is gone, so nothing more is asked of it.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(native.named('close'), isEmpty);
    expect(native.named('getCookies'), isEmpty);
  }, variant: linux);

  testWidgets('Cancel closes the window and leaves', (tester) async {
    final native = FakeWindow(tester);
    final out = await pumpStep(tester, testStep());
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(out.cancelled, 1);
    expect(native.named('close'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
    expect(native.named('close'), hasLength(1), reason: 'closed once');
  }, variant: linux);

  testWidgets('Done submits what is in before the URL is reached', (tester) async {
    final native = FakeWindow(tester);
    final out = await pumpStep(tester, testStep());
    await native.send('onLoadStop', {'url': 'https://example.com/login'});
    await native.handler('sbFound', ['request_body', 'csrf', 'C1', 'https://example.com/api/login']);
    await native.handler('sbExtracted', [jsonEncode({'title': 'T1'})]);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(out.submitted, {'sid': 'S1', 'token': 'tok-1', 'csrf': 'C1', 'title': 'T1'});
    expect(native.named('close'), hasLength(1));
  }, variant: linux);

  testWidgets('a hidden login opens no window on screen and shows a spinner', (tester) async {
    final native = FakeWindow(tester);
    await pumpStep(tester, testStep(hidden: true));
    expect(native.opened['hidden'], isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(native.named('close'), hasLength(1));
  }, variant: linux);

  testWidgets('says so when the window cannot open', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(loginWindowChannel, (call) async {
      throw PlatformException(code: 'bad_args', message: 'Expected a url');
    });
    final out = await pumpStep(tester, testStep());
    await tester.pump();
    expect(find.textContaining("Couldn't open the sign-in window"), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    expect(out.cancelled, 1);
  }, variant: linux);
}
