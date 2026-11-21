// Whether notifications hide who sent a message. The choice is a file in
// the app's support directory, so it goes when the app is removed and a
// fresh install starts with it off. On iOS the notification extension, a
// separate process, draws the notifications: it reads a copy the native
// side keeps in the keychain group it shares with the app.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'push.dart';

/// Where the choice is kept.
class NotificationPrivacyStore {
  const NotificationPrivacyStore({required this.file, this.extension});

  /// The file that exists while senders are hidden.
  final Future<File> Function() file;

  /// Tells the iOS notification extension. Null where the app shows its
  /// own notifications.
  final Future<void> Function(bool hide)? extension;

  Future<bool> read() async => (await file()).exists();

  /// The extension hides first and shows last, so a failure part-way
  /// never leaves it showing senders the setting says are hidden.
  Future<void> write(bool hide) async {
    final f = await file();
    if (hide) {
      await extension?.call(true);
      await f.create(recursive: true);
    } else {
      if (await f.exists()) await f.delete();
      await extension?.call(false);
    }
  }
}

final notificationPrivacyStoreProvider = Provider<NotificationPrivacyStore>(
  (ref) => NotificationPrivacyStore(
    file: () async => File('${(await getApplicationSupportDirectory()).path}/hide_notification_sender'),
    extension: pushSupported ? (hide) => pushChannel.invokeMethod<void>('setHideSender', hide) : null,
  ),
);

/// Whether notifications hide who sent a message: off until it's turned on
/// in Settings. Anything showing a notification treats a failure to read
/// it as on.
final hideNotificationSenderProvider =
    AsyncNotifierProvider<HideNotificationSender, bool>(HideNotificationSender.new);

class HideNotificationSender extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final store = ref.watch(notificationPrivacyStoreProvider);
    final hide = await store.read();
    // The keychain outlives the app's files (a reinstall, a restored
    // backup), so each launch puts the extension's copy right.
    try {
      await store.extension?.call(hide);
    } catch (_) {
      // The next launch or change tries again.
    }
    return hide;
  }

  /// Throws, leaving the setting as it was, when it can't be saved.
  Future<void> set(bool hide) async {
    await ref.read(notificationPrivacyStoreProvider).write(hide);
    state = AsyncData(hide);
  }
}
