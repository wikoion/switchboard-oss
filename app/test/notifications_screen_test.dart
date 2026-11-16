import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/state/push.dart';
import 'package:switchboard/src/ui/notifications_screen.dart';

class _On extends PushController {
  @override
  Future<bool> build() async => true;
}

void main() {
  testWidgets('shows iOS\'s preview setting and opens iOS Settings to change it', (tester) async {
    var previews = 'whenUnlocked';
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pushChannel, (call) async {
      calls.add(call.method);
      return call.method == 'previews' ? previews : null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pushChannel, null));

    await tester.pumpWidget(ProviderScope(
      overrides: [pushProvider.overrideWith(_On.new)],
      child: const MaterialApp(home: NotificationsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('When unlocked'), findsOneWidget);
    expect(find.textContaining('Hidden on the lock screen'), findsOneWidget);

    await tester.tap(find.text('Show message text'));
    expect(calls, contains('openNotificationSettings'));

    // Changed in iOS Settings, then back to the app.
    previews = 'always';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Always'), findsOneWidget);
  });
}
