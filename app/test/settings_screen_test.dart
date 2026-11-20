import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/notification_privacy.dart';
import 'package:switchboard/src/state/search.dart';
import 'package:switchboard/src/ui/settings_screen.dart';

/// The setting's file, without the disk: widget tests run on fake time.
class MemoryStore extends NotificationPrivacyStore {
  MemoryStore() : super(file: () async => File('unused'));

  bool hide = false;
  bool broken = false;

  @override
  Future<bool> read() async => hide;

  @override
  Future<void> write(bool hide) async {
    if (broken) throw const FileSystemException('disk full');
    this.hide = hide;
  }
}

void main() {
  /// One run of the app, open at Settings.
  Future<void> launch(WidgetTester tester, MemoryStore store) async {
    await tester.pumpWidget(ProviderScope(
      // A new scope each time, as a relaunch would have.
      key: UniqueKey(),
      overrides: [
        notificationPrivacyStoreProvider.overrideWithValue(store),
        indexStatusProvider.overrideWithValue(const AsyncLoading<IndexStatus>()),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();
  }

  bool switchOn(WidgetTester tester) =>
      tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Hide sender in notifications')).value;

  testWidgets('hiding the sender is off at first, and stays as set across relaunches', (tester) async {
    final store = MemoryStore();
    await launch(tester, store);
    expect(switchOn(tester), isFalse);

    await tester.tap(find.text('Hide sender in notifications'));
    await tester.pumpAndSettle();
    expect(switchOn(tester), isTrue);
    expect(store.hide, isTrue);

    await launch(tester, store);
    expect(switchOn(tester), isTrue);

    await tester.tap(find.text('Hide sender in notifications'));
    await tester.pumpAndSettle();
    expect(switchOn(tester), isFalse);
    expect(store.hide, isFalse);

    await launch(tester, store);
    expect(switchOn(tester), isFalse);
  });

  testWidgets("a change that can't be saved says so and doesn't show as made", (tester) async {
    final store = MemoryStore()..broken = true;
    await launch(tester, store);
    await tester.tap(find.text('Hide sender in notifications'));
    await tester.pumpAndSettle();
    expect(switchOn(tester), isFalse);
    expect(find.textContaining("Couldn't change that"), findsOneWidget);
  });
}
