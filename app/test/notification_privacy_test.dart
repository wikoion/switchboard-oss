import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/state/notification_privacy.dart';

void main() {
  late Directory support;
  late File file;

  setUp(() {
    support = Directory.systemTemp.createTempSync('switchboard-privacy');
    file = File('${support.path}/nested/hide_notification_sender');
  });
  tearDown(() => support.deleteSync(recursive: true));

  /// One run of the app, over the same support directory.
  ProviderContainer launch({Future<void> Function(bool hide)? extension}) {
    final container = ProviderContainer(overrides: [
      notificationPrivacyStoreProvider
          .overrideWithValue(NotificationPrivacyStore(file: () async => file, extension: extension)),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('senders show on a fresh install and after an upgrade', () async {
    expect(await launch().read(hideNotificationSenderProvider.future), isFalse);
    expect(file.existsSync(), isFalse, reason: 'reading the setting writes nothing');
  });

  test('the setting persists across relaunches, both ways', () async {
    final first = launch();
    await first.read(hideNotificationSenderProvider.future);
    await first.read(hideNotificationSenderProvider.notifier).set(true);
    expect(first.read(hideNotificationSenderProvider).value, isTrue);

    final second = launch();
    expect(await second.read(hideNotificationSenderProvider.future), isTrue);
    await second.read(hideNotificationSenderProvider.notifier).set(false);
    expect(second.read(hideNotificationSenderProvider).value, isFalse);

    expect(await launch().read(hideNotificationSenderProvider.future), isFalse);
  });

  test('each launch and each change tells the notification extension', () async {
    final told = <bool>[];
    Future<void> extension(bool hide) async => told.add(hide);

    final first = launch(extension: extension);
    await first.read(hideNotificationSenderProvider.future);
    expect(told, [false], reason: 'the keychain can outlive the app, so a fresh install says so');
    await first.read(hideNotificationSenderProvider.notifier).set(true);
    expect(told, [false, true]);

    await launch(extension: extension).read(hideNotificationSenderProvider.future);
    expect(told, [false, true, true]);
  });

  test('the extension hides before the app says so, and shows after', () async {
    final seen = <(bool, bool)>[];
    final store = NotificationPrivacyStore(
      file: () async => file,
      extension: (hide) async => seen.add((hide, file.existsSync())),
    );
    await store.write(true);
    await store.write(false);
    expect(seen, [(true, false), (false, false)]);
  });

  test("a change the extension can't take isn't made", () async {
    var refuse = false;
    final app = launch(extension: (hide) async {
      if (refuse) throw StateError('keychain');
    });
    await app.read(hideNotificationSenderProvider.future);
    refuse = true;
    await expectLater(app.read(hideNotificationSenderProvider.notifier).set(true), throwsStateError);
    expect(app.read(hideNotificationSenderProvider).value, isFalse);
    expect(file.existsSync(), isFalse);
  });

  test('a launch survives an extension that fails', () async {
    file.createSync(recursive: true);
    final app = launch(extension: (hide) async => throw StateError('keychain'));
    expect(await app.read(hideNotificationSenderProvider.future), isTrue);
  });
}
