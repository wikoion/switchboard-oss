import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/hub.dart';
import 'package:switchboard/src/ui/link_screen.dart';
import 'package:switchboard/src/ui/login_window.dart';

final whatsapp = Bridge(
  id: 'whatsapp',
  network: 'WhatsApp',
  reachable: true,
  supportsApi: true,
  flows: [
    LoginFlow(id: 'qr', name: 'QR', description: 'Scan a QR code'),
    LoginFlow(id: 'phone', name: 'Pairing code', description: 'Input your phone number'),
  ],
);

/// A scripted Hub: each path answers with the next queued JSON body, or
/// waits on a completer for long polls.
class FakeHub {
  final calls = <(String, String, String?)>[];
  final replies = <String, List<Object>>{};

  void reply(String pathEnd, Object body) => replies.putIfAbsent(pathEnd, () => []).add(body);

  Future<HubResponse> send(String method, String path, String? body) async {
    calls.add((method, path, body));
    final key = replies.keys.firstWhere((k) => path.endsWith(k), orElse: () => '');
    final queue = replies[key];
    if (queue == null || queue.isEmpty) return HubResponse(status: 200, body: '{}');
    final next = queue.removeAt(0);
    final value = next is Completer<Object> ? await next.future : next;
    return HubResponse(status: 200, body: jsonEncode(value));
  }
}

Widget app(FakeHub hub, {String? flowId}) => ProviderScope(
      overrides: [
        hubProvider.overrideWithValue(HubApi(hub.send)),
        bridgesProvider.overrideWith((ref) async => [whatsapp]),
      ],
      child: MaterialApp(home: LinkScreen(bridgeId: 'whatsapp', flowId: flowId)),
    );

/// Screens with a spinner never settle; pump a few frames instead.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, Object?> step(String type, String id, Map<String, Object?> extra) =>
    {'login_id': 'L1', 'type': type, 'step_id': id, 'instructions': 'Do the thing', ...extra};

void main() {
  testWidgets('pairing code: pick flow, enter number, see code, complete', (tester) async {
    final hub = FakeHub();
    final paired = Completer<Object>();
    hub.reply('/login/start/phone', step('user_input', 'phone', {
      'user_input': {
        'fields': [
          {'type': 'phone_number', 'id': 'phone_number', 'name': 'Phone number', 'pattern': r'^\+[0-9]+$'},
        ],
      },
    }));
    hub.reply('/phone/user_input', step('display_and_wait', 'code', {
      'display_and_wait': {'type': 'code', 'data': 'ABCD-EFGH'},
    }));
    hub.reply('/code/display_and_wait', paired);

    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();
    expect(find.text('How do you want to link WhatsApp?'), findsOneWidget);

    await tester.tap(find.text('Pairing code'));
    await tester.pumpAndSettle();
    expect(find.text('Phone number'), findsOneWidget);

    // The bridge's pattern is checked before submitting.
    await tester.enterText(find.byType(TextFormField), '07700 900123');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text("That doesn't look right"), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), '+447700900123');
    await tester.tap(find.text('Continue'));
    await settle(tester);
    expect(find.text('ABCD-EFGH'), findsOneWidget);
    expect(find.text('Waiting for your phone'), findsOneWidget);
    final submitted = hub.calls.firstWhere((c) => c.$2.endsWith('/user_input'));
    expect(jsonDecode(submitted.$3!), {'phone_number': '+447700900123'});

    paired.complete(step('complete', 'done', {'complete': {'user_login_id': '447700900123'}}));
    await settle(tester);
    expect(find.text('WhatsApp linked'), findsOneWidget);
  });

  testWidgets('QR step offers the phone-number flow and cancels when left', (tester) async {
    final hub = FakeHub();
    hub.reply('/login/start/qr', step('display_and_wait', 'qr', {
      'display_and_wait': {'type': 'qr', 'data': '2@abc,def'},
    }));
    hub.reply('/qr/display_and_wait', Completer<Object>());

    await tester.pumpWidget(app(hub, flowId: 'qr'));
    await settle(tester);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('On this phone? Use phone number instead'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    expect(hub.calls.any((c) => c.$2.endsWith('/login/cancel/L1')), isTrue);
  });

  testWidgets('Linux: a cookies step opens the sign-in window; closing it leaves and cancels', (tester) async {
    final native = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(loginWindowChannel, (call) async {
      native.add(call);
      return null;
    });
    final instagram = Bridge(
      id: 'instagram',
      network: 'Instagram',
      reachable: true,
      supportsApi: true,
      flows: [LoginFlow(id: 'cookies', name: 'Web', description: 'Sign in on the web')],
    );
    final hub = FakeHub();
    hub.reply('/login/start/cookies', step('cookies', 'web', {
      'cookies': {
        'url': 'https://www.instagram.com/accounts/login/',
        'fields': [
          {'id': 'sessionid', 'required': true, 'sources': [{'type': 'cookie', 'name': 'sessionid', 'cookie_domain': 'instagram.com'}]},
        ],
      },
    }));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hubProvider.overrideWithValue(HubApi(hub.send)),
        bridgesProvider.overrideWith((ref) async => [instagram]),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LinkScreen(bridgeId: 'instagram')),
            ),
            child: const Text('Add'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Add'));
    await settle(tester);
    final open = native.singleWhere((c) => c.method == 'open').arguments as Map;
    expect(open['url'], 'https://www.instagram.com/accounts/login/');
    expect(find.textContaining('in the window that opened'), findsOneWidget);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      loginWindowChannel.name,
      loginWindowChannel.codec.encodeMethodCall(MethodCall('onClosed', {'id': open['id']})),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.text('Add'), findsOneWidget);
    expect(hub.calls.any((c) => c.$2.endsWith('/login/cancel/L1')), isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('unsupported steps say so', (tester) async {
    final hub = FakeHub();
    hub.reply('/login/start/qr', step('webauthn', 'wa', {'webauthn': {}}));
    await tester.pumpWidget(app(hub, flowId: 'qr'));
    await tester.pumpAndSettle();
    expect(find.textContaining("isn't supported in the app yet"), findsOneWidget);
  });
}
